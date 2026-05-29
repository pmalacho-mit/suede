# Associative array to store URL -> file path mappings
declare -A CURL_MOCK_URLS

# Mock curl to intercept specific URLs and return local file content
mock_curl_url() {
  local url="$1"
  local file_path="$2"
  
  if [[ ! -f "$file_path" ]]; then
    log_error "Mock file not found: $file_path"
    return 1
  fi
  
  CURL_MOCK_URLS["$url"]="$file_path"
}

# Enable URL mocking by overriding curl
enable_url_mocking() {
  # Create a curl wrapper function
  eval 'curl() {
    local url=""
    local output_file=""
    local use_mock=false
    
    # Parse arguments to find URL and output file
    local args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o|--output)
          output_file="$2"
          args+=("$1" "$2")
          shift 2
          ;;
        -*)
          args+=("$1")
          shift
          ;;
        *)
          url="$1"
          args+=("$1")
          shift
          ;;
      esac
    done
    
    # Check if this URL should be mocked
    for mock_url in "${!CURL_MOCK_URLS[@]}"; do
      if [[ "$url" == "$mock_url" ]]; then
        use_mock=true
        local mock_file="${CURL_MOCK_URLS[$mock_url]}"
        
        # Return the file content
        if [[ -n "$output_file" ]]; then
          cat "$mock_file" > "$output_file"
        else
          cat "$mock_file"
        fi
        return 0
      fi
    done
    
    # If not mocked, use real curl
    command curl "${args[@]}"
  }'
}

# Disable URL mocking
disable_url_mocking() {
  unset -f curl 2>/dev/null || true
  unset CURL_MOCK_URLS
  declare -gA CURL_MOCK_URLS
}