#!/bin/zsh
set -u

socket_path="/tmp/verge/verge-mihomo.sock"
candidates_file="${1:?candidate file required}"
results_file="${2:?results file required}"
duration_seconds="${3:-300}"
interval_seconds="${4:-30}"

: > "$results_file"
started_at=$(date +%s)
round=0

while (( $(date +%s) - started_at < duration_seconds )); do
  round=$((round + 1))
  round_started=$(date +%s)
  round_file="/tmp/codex-node-round-${round}.tsv"

  xargs -I '{}' -P 6 sh -c '
    node="$1"
    round_number="$2"
    socket="$3"
    encoded=$(printf "%s" "$node" | jq -sRr @uri)
    chat=$(curl --silent --max-time 7 --unix-socket "$socket" \
      "http://localhost/proxies/$encoded/delay?timeout=5000&url=https%3A%2F%2Fchatgpt.com%2F" \
      | jq -r ".delay // 0")
    api=$(curl --silent --max-time 7 --unix-socket "$socket" \
      "http://localhost/proxies/$encoded/delay?timeout=5000&url=https%3A%2F%2Fapi.openai.com%2Fv1%2Fmodels" \
      | jq -r ".delay // 0")
    printf "%s\t%s\t%s\t%s\n" "$round_number" "$node" "$chat" "$api"
  ' _ '{}' "$round" "$socket_path" < "$candidates_file" > "$round_file"

  cat "$round_file" >> "$results_file"
  summary=$(awk 'BEGIN { FS="\t" } $3>0 && $3<=2000 && $4>0 && $4<=2000 { ok++ } END { print ok+0 }' "$round_file")
  total=$(wc -l < "$round_file" | tr -d ' ')
  elapsed=$(( $(date +%s) - started_at ))
  echo "ROUND $round elapsed=${elapsed}s stable=$summary/$total"

  now=$(date +%s)
  total_elapsed=$((now - started_at))
  if (( total_elapsed >= duration_seconds )); then
    break
  fi

  round_elapsed=$((now - round_started))
  remaining=$((interval_seconds - round_elapsed))
  until_deadline=$((duration_seconds - total_elapsed))
  if (( remaining > until_deadline )); then
    remaining=$until_deadline
  fi
  if (( remaining > 0 )); then
    sleep "$remaining"
  fi
done

echo "COMPLETE rounds=$round elapsed=$(( $(date +%s) - started_at ))s"
