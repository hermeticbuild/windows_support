#!/bin/sh
# Usage: makemsix_pack.sh <makemsix> <layout_dir> <package>
#
# Runs `makemsix pack`, failing first with a clear message if the layout has symlinked directories,
# makemsix fails on them with an obscure "read failed" error.
set -eu

makemsix="$1"
layout="$2"
package="$3"

symlinked_dirs="$(cd "$layout" && find . -type l -exec test -d {} \; -print)"
if [ -n "$symlinked_dirs" ]; then
    echo "error: the layout $layout must not contain symlinked directories, makemsix cannot pack them:" >&2
    echo "$symlinked_dirs" | sed 's#^\./#  #' >&2
    exit 1
fi

exec "$makemsix" pack -d "$layout" -p "$package"
