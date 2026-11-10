#!/bin/bash
if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi
NEW_VERSION="$1"
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" script.sh && rm script.sh.bak
cp script.sh skills/git-recap/scripts/git-recap.sh
echo "Updated script.sh and the bundled skill script to version $NEW_VERSION"
