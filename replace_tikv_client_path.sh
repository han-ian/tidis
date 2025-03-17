#!/bin/bash

# 定义原始 URL 和目标 URL
OLD_URL="https://git.garena.com/yin.han/tikv-client-rust.git"
NEW_URL="https://kvstore:wyN8JH_qmrPFkywFJ3tp@git.garena.com/yin.han/tikv-client-rust.git"

# 需要修改的文件
TARGET_FILE="Cargo.toml"

# 使用 sed 进行替换
sed -i "s|$OLD_URL|$NEW_URL|g" "$TARGET_FILE"

echo "URL 替换完成: $OLD_URL -> $NEW_URL"
