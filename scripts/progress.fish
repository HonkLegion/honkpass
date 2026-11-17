# Shared Fish entry point for compact step output. Commands remain separate argv elements.
set -l step_runner (path dirname (status --current-filename))/step-output.py
function run_step --argument-names title log --inherit-variable step_runner
    python3 "$step_runner" --title "$title" --log "$log" -- $argv[3..]
end
