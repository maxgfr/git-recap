#!/bin/bash
if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi
NEW_VERSION="$1"
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" git-recap && rm git-recap.bak
echo "Updated git-recap to version $NEW_VERSION"
