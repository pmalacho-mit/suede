strip_cr() {
  # usage: clean_str="$(strip_cr "$original_str")"
  local input="$1"
  printf '%s' "${input//$'\r'/}"
}