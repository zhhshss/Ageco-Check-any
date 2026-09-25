#!/usr/bin/env bash
# run-all.sh - Batch health-check runner with internal 50-minute loop
# Loops forever unless MAX_DURATION_SEC is set (GitHub Actions still caps a job
# at 6h; the workflow chains the next run instead of stopping for good).
# Supports local usage via .env file or ANYROUTER_TOKENS env var.
# Usage: run-all.sh [--once]
#
# Pacing env vars:
#   REQUEST_INTERVAL_SEC - seconds between two consecutive requests; when set it
#                          wins over the defaults below and is used both between
#                          tokens and between rounds (blank = legacy pacing)
#   SLOW_INTERVAL_MIN    - once one request comes back healthy, slow down to this
#                          keepalive pace in minutes (default 30, 0 = stay fast)
#   SLEEP_BETWEEN_TOKENS - default 30s (+/- 10s jitter) between tokens
#   SLEEP_BETWEEN_ROUNDS - default 3000s between rounds
#   MAX_DURATION_SEC     - seconds to run before exiting; default 0 = never stop
#                          on its own (0/none/unlimited all mean "no limit")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse args ---
ONCE=false
if [ "${1:-}" = "--once" ]; then
    ONCE=true
fi

# --- Configuration ---
BASE_URL="${BASE_URL:-https://anyrouter.top}"
MODEL="${MODEL:-gpt-6-astra}"
# MODELS: 逗号分隔的多模型列表，每个 token 会依次对所有模型做保活
# 例如 MODELS="gpt-6-astra,claude-opus-5-5[1m]"
# 留空则回退到单个 MODEL 变量（向后兼容）
MODELS="${MODELS:-}"
SLEEP_BETWEEN_TOKENS="${SLEEP_BETWEEN_TOKENS:-30}"         # seconds between tokens
SLEEP_BETWEEN_ROUNDS="${SLEEP_BETWEEN_ROUNDS:-3000}"       # ~50 minutes between rounds
# Fixed seconds between two consecutive requests. When set it wins over both
# defaults above, so "one request every N seconds" also holds between rounds.
REQUEST_INTERVAL_SEC="${REQUEST_INTERVAL_SEC:-}"
# Blank or whitespace-only (e.g. someone typed a space in the Actions box) means
# "not set": fall back to the built-in pacing below.
REQUEST_INTERVAL_SEC="$(printf '%s' "$REQUEST_INTERVAL_SEC" | tr -d '[:space:]')"
if [ -n "$REQUEST_INTERVAL_SEC" ]; then
    case "$REQUEST_INTERVAL_SEC" in
        *[!0-9]*)
            echo "ERROR: REQUEST_INTERVAL_SEC 必须是整数秒（当前值 '$REQUEST_INTERVAL_SEC'）" >&2
            exit 1
            ;;
    esac
    SLEEP_BETWEEN_TOKENS="$REQUEST_INTERVAL_SEC"
    SLEEP_BETWEEN_ROUNDS="$REQUEST_INTERVAL_SEC"
fi
# Slow keepalive pace to fall back to after the first healthy answer (minutes).
# 0 disables the slow-down, and it only kicks in when a fast interval is set.
SLOW_INTERVAL_MIN="${SLOW_INTERVAL_MIN:-30}"
case "$SLOW_INTERVAL_MIN" in
    *[!0-9]*)
        echo "ERROR: SLOW_INTERVAL_MIN 必须是整数分钟（当前值 '$SLOW_INTERVAL_MIN'）" >&2
        exit 1
        ;;
esac
SLOW_INTERVAL_SEC=$(( SLOW_INTERVAL_MIN * 60 ))
if [ -z "$REQUEST_INTERVAL_SEC" ]; then
    SLOW_INTERVAL_SEC=0
fi
SLOWDOWN_ACTIVE=false
MAX_DURATION_SEC="${MAX_DURATION_SEC:-0}"                  # 0/none/unlimited = 不自动停止
case "$MAX_DURATION_SEC" in
    0|none|None|unlimited|inf|infinite) MAX_DURATION_SEC="" ;;
esac
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"
BARK_URL="${BARK_URL:-}"
BARK_KEY="${BARK_KEY:-}"

# Remaining seconds until the time limit, or "inf" when there is no limit at all
remaining_sec() {
    if [ -z "$MAX_DURATION_SEC" ]; then
        echo "inf"
    else
        echo $(( MAX_DURATION_SEC - ($(date +%s) - START_TIME) ))
    fi
}

# --- Load tokens ---
load_tokens() {
    # 1) Try env var
    if [ -n "${ANYROUTER_TOKENS:-}" ]; then
        echo "$ANYROUTER_TOKENS"
        return
    fi
    # 2) Try .env file
    if [ -f "$SCRIPT_DIR/../.env" ]; then
        local val
        val=$(grep -E '^ANYROUTER_TOKENS=' "$SCRIPT_DIR/../.env" 2>/dev/null | sed 's/^ANYROUTER_TOKENS=//' | sed 's/^"//;s/"$//' || true)
        if [ -n "$val" ]; then
            echo "$val" | tr ',' '\n'
            return
        fi
    fi
    echo "ERROR: 没有找到 token。请设置 ANYROUTER_TOKENS 环境变量，或创建 .env 文件。" >&2
    exit 1
}

# --- Email report ---
send_email() {
    local subject="$1" body="$2"
    if [ -z "$QQ_EMAIL" ] || [ -z "$QQ_SMTP_AUTH_CODE" ]; then
        echo "  (跳过邮件: 未配置 QQ_EMAIL 或 QQ_SMTP_AUTH_CODE)"
        return 0
    fi

    # Verify curl supports SMTP (GitHub Actions curl usually does)
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  邮件发送失败: 当前 curl 未编译 SMTP 支持"
        return 1
    fi

    # Write email to temp file (more reliable than here-string + stdin)
    local mail_file
    mail_file=$(mktemp)
    cat > "$mail_file" <<EOF
From: $QQ_EMAIL
To: $QQ_EMAIL
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF

    echo "  正在通过 QQ SMTP 发邮件到 $QQ_EMAIL ..."

    # SMTP_DEBUG=true (Actions: smtp_debug) prints the raw SMTP conversation,
    # which is the fastest way to see why QQ rejects a message.
    local curl_opts=()
    if [ "${SMTP_DEBUG:-}" = "true" ]; then
        curl_opts+=(-v)
        echo "  (SMTP_DEBUG: 打印原始 SMTP 会话)"
    fi

    local curl_exit=0 url
    # QQ defaults: implicit TLS first, then the STARTTLS port. SMTP_URL replaces
    # them entirely (QQ Mail refuses to send from cloud/datacenter IPs such as
    # GitHub runners, so another provider is often the only way out).
    local smtp_urls=("smtps://smtp.qq.com:465" "smtp://smtp.qq.com:587")
    if [ -n "${SMTP_URL:-}" ]; then
        smtp_urls=("$SMTP_URL")
    fi
    for url in "${smtp_urls[@]}"; do
        curl_exit=0
        curl -sS --ssl-reqd --fail-with-body ${curl_opts[@]+"${curl_opts[@]}"} \
            --url "$url" \
            --user "$QQ_EMAIL:$QQ_SMTP_AUTH_CODE" \
            --login-options "AUTH=LOGIN" \
            --mail-from "$QQ_EMAIL" \
            --mail-rcpt "$QQ_EMAIL" \
            --upload-file - < "$mail_file" \
            || curl_exit=$?
        if [ "$curl_exit" -eq 0 ]; then
            break
        fi
        echo "  通过 ${url} 发送失败 (curl 退出码: $curl_exit)"
    done

    rm -f "$mail_file"

    if [ "$curl_exit" -eq 0 ]; then
        echo "  邮件已发送到 $QQ_EMAIL"
        return 0
    else
        echo "  邮件发送 FAILED (curl 退出码: $curl_exit)"
        echo "  常见原因:"
        echo "    - QQ_SMTP_AUTH_CODE 不对（它不是 QQ 密码，而是授权码）"
        echo "    - 生成位置: QQ 邮箱 -> 设置 -> 账号 -> POP3/IMAP/SMTP 服务"
        echo "    - 网络/防火墙拦住了 smtps://smtp.qq.com:465"
        echo "    - QQ 拒绝从机房 IP（GitHub runner）发信: 请把 SMTP_URL 换成别的邮箱服务"
        echo "    - 用 SMTP_DEBUG=true（Actions 输入 smtp_debug）重跑，可看到 QQ 的原始回复"
        return 1
    fi
}

# --- Bark push ---
send_bark() {
    local title="$1" body="$2"
    if [ -z "$BARK_URL" ] || [ -z "$BARK_KEY" ]; then
        echo "  (跳过 Bark: 未配置 BARK_URL 或 BARK_KEY)"
        return 0
    fi
    local bark_server="${BARK_URL%/}"
    local url="${bark_server}/${BARK_KEY}/${title}/${body}"
    url=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$url', safe=':/'))" 2>/dev/null || echo "$url")
    local resp
    resp=$(curl -sS --max-time 10 "$url" 2>&1)
    if echo "$resp" | grep -q '"code":200'; then
        echo "  Bark 推送成功"
        return 0
    else
        echo "  Bark 推送失败: $resp"
        return 1
    fi
}

# --- Load tokens ---
TOKENS_DATA=$(load_tokens)
mapfile -t TOKENS <<< "$TOKENS_DATA"
if [ ${#TOKENS[@]} -eq 0 ]; then
    echo "ERROR: 没有加载到 token，退出。" >&2
    exit 1
fi
echo "已加载 ${#TOKENS[@]} 个 token"
echo "接口地址: $BASE_URL"

# Build the effective model list: MODELS wins when set, otherwise fall back to MODEL.
if [ -n "$MODELS" ]; then
    IFS=',' read -r -a MODEL_LIST <<< "$MODELS"
    # Trim whitespace around each model id
    for mi in "${!MODEL_LIST[@]}"; do
        MODEL_LIST[$mi]="$(printf '%s' "${MODEL_LIST[$mi]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    done
else
    MODEL_LIST=("$MODEL")
fi
if [ ${#MODEL_LIST[@]} -eq 0 ]; then
    echo "ERROR: 模型列表为空，退出。" >&2
    exit 1
fi
echo "模型列表: ${MODEL_LIST[*]}"
if [ -n "$REQUEST_INTERVAL_SEC" ]; then
    echo "请求间隔: ${REQUEST_INTERVAL_SEC}s（固定，无抖动）"
    if [ "$SLOW_INTERVAL_SEC" -gt 0 ]; then
        echo "首次成功后降速: ${SLOW_INTERVAL_MIN} 分钟保活节奏"
    else
        echo "首次成功后降速: 已禁用"
    fi
fi
echo ""

START_TIME=$(date +%s)
ROUND=1
ALL_RESULTS=""
HAS_SENT_REPORT=false

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$(remaining_sec)

    if [ "$REMAINING" != "inf" ] && [ "$REMAINING" -le 0 ]; then
        echo "=== 达到时间上限，退出 ==="
        break
    fi

    echo "========================================"
    echo " 第 $ROUND 轮  |  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    if [ "$REMAINING" = "inf" ]; then
        echo " 已用: ${ELAPSED}s  |  剩余: 无限"
    else
        echo " 已用: ${ELAPSED}s  |  剩余: ~${REMAINING}s"
    fi
    echo "========================================"

    ROUND_RESULTS=""
    ROUND_SUCCESS=0
    ROUND_FAIL=0

    for i in "${!TOKENS[@]}"; do
        token="${TOKENS[$i]}"
        token_preview="${token:0:5}..."

        # Check remaining time before each token
        NOW=$(date +%s)
        if [ -n "$MAX_DURATION_SEC" ] && [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "已达时间上限，中途结束本轮。"
            break
        fi

        # 一个 token 依次对所有模型保活
        for CURRENT_MODEL in "${MODEL_LIST[@]}"; do
            # Check remaining time before each request
            NOW=$(date +%s)
            if [ -n "$MAX_DURATION_SEC" ] && [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
                echo "已达时间上限，中途结束本轮。"
                break 2
            fi

            echo "[$((i+1))/${#TOKENS[@]}][$CURRENT_MODEL] 正在测试 $token_preview ..."

            if result=$(bash "$SCRIPT_DIR/keepalive.sh" "$token" "$BASE_URL" "$CURRENT_MODEL" 2>&1); then
                echo "$result"
                echo "  ✓ $token_preview [$CURRENT_MODEL] 正常"
                ROUND_RESULTS+="  ✓ $token_preview [$CURRENT_MODEL] 正常"$'\n'
                ROUND_SUCCESS=$((ROUND_SUCCESS + 1))

                # First healthy answer: stop hammering and keep the account warm at
                # the slow pace instead (rounds become SLOW_INTERVAL_SEC apart, so
                # every token is exercised once per SLOW_INTERVAL_MIN minutes).
                if [ "$SLOWDOWN_ACTIVE" = false ] && [ "$SLOW_INTERVAL_SEC" -gt 0 ]; then
                    SLOWDOWN_ACTIVE=true
                    SLEEP_BETWEEN_ROUNDS="$SLOW_INTERVAL_SEC"
                    echo "  >>> 首次收到正常回复 - 降速到 ${SLOW_INTERVAL_MIN} 分钟保活节奏"
                    ROUND_RESULTS+="  >>> 首次收到正常回复: 已切换到 ${SLOW_INTERVAL_MIN} 分钟保活节奏"$'\n'
                fi
            else
                echo "$result"
                echo "  ✗ $token_preview [$CURRENT_MODEL] 失败"
                ROUND_RESULTS+="  ✗ $token_preview [$CURRENT_MODEL] 失败"$'\n'
                ROUND_FAIL=$((ROUND_FAIL + 1))
            fi

            # Pace the requests between model calls of the same token
            if [ -n "$REQUEST_INTERVAL_SEC" ]; then
                WAIT_SEC="$REQUEST_INTERVAL_SEC"
            else
                WAIT_SEC=$(( SLEEP_BETWEEN_TOKENS + (RANDOM % 21) - 10 ))
                [ "$WAIT_SEC" -lt 10 ] && WAIT_SEC=10
            fi
            echo "  等待 ${WAIT_SEC}s ..."
            sleep "$WAIT_SEC"
        done
    done

    # Accumulate round results
    ALL_RESULTS+="--- 第 $ROUND 轮 ($(date '+%Y-%m-%d %H:%M')) ---"$'\n'
    ALL_RESULTS+="$ROUND_RESULTS"$'\n'
    ALL_RESULTS+="第 $ROUND 轮汇总: 成功 $ROUND_SUCCESS，失败 $ROUND_FAIL"$'\n'$'\n'

    echo ""
    echo "--- 第 $ROUND 轮汇总: 成功 $ROUND_SUCCESS，失败 $ROUND_FAIL ---"

    ROUND=$((ROUND + 1))

    # If --once mode, exit after the first round
    if [ "$ONCE" = true ]; then
        echo ""
        echo "=== --once 模式: 单轮已完成，退出 ==="
        break
    fi

    # Check if we should send final report (last round before time limit)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$(remaining_sec)

    if [ "$REMAINING" != "inf" ] && [ "$REMAINING" -le "$((SLEEP_BETWEEN_ROUNDS + 120))" ] \
        && [ "$HAS_SENT_REPORT" = false ]; then
        HAS_SENT_REPORT=true
        echo ""
        echo "=== 发送最终报告 ==="
        send_email "Anyrouter 保活报告 ($(date '+%Y-%m-%d'))" "$ALL_RESULTS" || true
        send_bark "Anyrouter 保活报告" "$(echo "$ALL_RESULTS" | head -20 | tr '\n' '|')" || true
        echo ""

        # Do one more round if time allows, but signal it's the last
        if [ "$REMAINING" -le 0 ]; then
            break
        fi
    fi

    # Sleep until next round (if we have time)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$(remaining_sec)

    if [ "$REMAINING" = "inf" ] || [ "$REMAINING" -gt "$SLEEP_BETWEEN_ROUNDS" ]; then
        echo "休眠 ${SLEEP_BETWEEN_ROUNDS}s，等待第 $ROUND 轮 ..."
        sleep "$SLEEP_BETWEEN_ROUNDS"
    elif [ "$REMAINING" -gt 60 ]; then
        echo "休眠 ${REMAINING}s（剩余时间）..."
        sleep "$REMAINING"
    else
        echo "已达到时间上限。"
    fi
done

# Final summary
echo ""
echo "========================================"
echo " 全部轮次完成。"
echo "$ALL_RESULTS"
echo "========================================"

# Send one final report if we never sent one (e.g. very short run)
if [ "$HAS_SENT_REPORT" = false ]; then
    send_email "Anyrouter 保活报告 ($(date '+%Y-%m-%d'))" "$ALL_RESULTS" || true
    send_bark "Anyrouter 保活报告" "$(echo "$ALL_RESULTS" | head -20 | tr '\n' '|')" || true
fi

echo "完成。"
