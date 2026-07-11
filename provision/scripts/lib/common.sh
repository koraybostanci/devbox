#!/bin/bash

stage() {
    printf '\n--- %s\n' "$1"
}

atomic_copy() {
    local source_file="$1" destination="$2" mode="${3:-600}"
    local temporary

    mkdir -p "$(dirname "$destination")"
    temporary="$(mktemp "$(dirname "$destination")/.deploy.XXXXXX")"
    cp "$source_file" "$temporary"
    chmod "$mode" "$temporary"
    mv "$temporary" "$destination"
}

version_equals() {
    [ "$1" = "$2" ]
}
