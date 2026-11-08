#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../query/_common.sh"

tat_tasks() {
    local invocation_id="$1" region="$2" hide_output="$3" filters
    filters=$(jq -cn --arg id "$invocation_id" '[{Name:"invocation-id",Values:[$id]}]')
    query_fetch tat DescribeInvocationTasks InvocationTaskSet true 0 100 true \
        --region "$region" --Filters "$filters" --HideOutput "$hide_output"
}

# Keep every per-instance state and missing target visible. SUCCESS requires an exit code.
tat_result() {
    local invocation_id="$1" expected="$2" tasks="$3"
    printf '%s\n' "$tasks" | jq --arg id "$invocation_id" --argjson expected "$expected" '
      def terminal: . == "SUCCESS" or . == "FAILED" or . == "TIMEOUT" or . == "TASK_TIMEOUT" or
        . == "DELIVER_FAILED" or . == "START_FAILED" or . == "CANCELLED" or . == "TERMINATED";
      .InvocationTaskSet as $tasks |
      ($expected - [$tasks[].InstanceId]) as $missing |
      ([$tasks[] | select((.TaskStatus | terminal) | not)] | length) as $running |
      ([$tasks[] | select((.TaskStatus | terminal) and (.TaskStatus != "SUCCESS" or .TaskResult.ExitCode != 0))] | length) as $failed |
      {InvocationId:$id, InvocationTaskSet:$tasks, _Pagination:._Pagination,
       Summary:{ExpectedCount:($expected|length), ReturnedCount:($tasks|length), MissingInstanceIds:$missing,
        RunningCount:$running, FailedCount:$failed,
        DroppedBytes:([$tasks[].TaskResult.Dropped // 0] | add // 0),
        Status:(if ($missing|length)>0 or $running>0 or ($tasks|length)==0 then "RUNNING"
          elif $failed>0 then "FAILED" else "SUCCESS" end)}}'
}

tat_print_result() {
    local result="$1" json="$2" show_output="$3"
    if [[ "$json" == true ]]; then printf '%s\n' "$result"; return 0; fi
    printf '%s\n' "$result" | jq -r '
      "执行 ID: \(.InvocationId)\n汇总: \(.Summary.Status)\n",
      (.InvocationTaskSet[] | "实例: \(.InstanceId)\n状态: \(.TaskStatus)\n退出码: \(.TaskResult.ExitCode // "未返回")\n错误: \(.ErrorInfo // "无")\n丢弃输出字节: \(.TaskResult.Dropped // 0)\n输出地址: \(.TaskResult.OutputUrl // "无")\n")'
    if [[ "$show_output" == true ]]; then
        printf '%s\n' "$result" | jq -r '.InvocationTaskSet[] |
          "=== \(.InstanceId) ===\n" + (if (.TaskResult.Output // "") == "" then "无输出" else (.TaskResult.Output | @base64d) end)'
    fi
    if [[ $(printf '%s\n' "$result" | jq '.Summary.DroppedBytes') -gt 0 ]]; then
        warn '输出已被 TAT 截断；查看返回的 OutputUrl（若有），不要将当前文本当成完整日志'
    fi
}
