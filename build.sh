#!/usr/bin/env bash
#==============================================================================
# build.sh — 构建镜像并打「日期标签」,保留可回滚的历史版本
#
#   1. 离线构建(Dockerfile + downloads/,不联网)
#   2. 给构建产物额外打 chw717/ai-agy:<YYYYMMDD> 日期标签
#   3. docker compose up -d 拉起容器
#
# 用法:
#   bash build.sh                     # 构建 + 打当天日期标签 + 启动
#   DATE_TAG=20260826 bash build.sh   # 指定日期(默认今天)
#
# 回滚到某天的镜像:
#   docker tag chw717/ai-agy:20260826 chw717/ai-agy:latest
#   docker compose up -d
#==============================================================================
set -euo pipefail

IMAGE="chw717/ai-agy"
DATE_TAG="${DATE_TAG:-$(date +%Y%m%d)}"

echo "[1/3] 构建镜像(离线)..."
docker compose build

echo "[2/3] 打日期标签 ${IMAGE}:${DATE_TAG} ..."
docker tag "${IMAGE}:latest" "${IMAGE}:${DATE_TAG}"

echo "[3/3] 启动容器..."
docker compose up -d

echo ""
echo "✅ 完成:${IMAGE}:latest 与 ${IMAGE}:${DATE_TAG} 现在指向同一镜像"
echo "   回滚到历史版本:"
echo "     docker tag ${IMAGE}:<日期> ${IMAGE}:latest && docker compose up -d"
