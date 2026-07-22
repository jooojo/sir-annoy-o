#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"

cd "$repo_root"
xcrun swift-format format \
    --configuration .swift-format \
    --in-place \
    --recursive \
    Sources \
    Tests \
    Packaging \
    Package.swift
