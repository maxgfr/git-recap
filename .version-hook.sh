#!/bin/bash
if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi
NEW_VERSION="$1"
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" script.sh && rm script.sh.bak
echo "Updated script.sh to version $NEW_VERSION"
