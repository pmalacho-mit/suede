set -e

# Find all .gitrepo files and extract their parent directories
SUBREPO_DIRS=$(find . -name ".gitrepo" -type f | sed 's|/\.gitrepo$||' | sort -u)

if [ -z "$SUBREPO_DIRS" ]; then
  echo "No subrepos found"
  exit 0
fi

echo "Found subrepos:"
echo "$SUBREPO_DIRS"
echo ""

# Pull each subrepo
for dir in $SUBREPO_DIRS; do
  echo "=================================================="
  echo "Updating subrepo: $dir"
  echo "=================================================="
  
  if git subrepo pull "$dir"; then
    echo "✓ Successfully pulled $dir"
  else
    echo "⚠ Failed to pull $dir (may be up to date or have conflicts)"
  fi
  echo ""
done