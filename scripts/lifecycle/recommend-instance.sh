#!/bin/bash
# 根据使用场景智能推荐服务器配置（多方案对比）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

根据使用场景智能推荐服务器配置，提供三种方案对比

选项:
  --scene <scene>         使用场景（见下方列表）
  --region <region>       地域，默认 $DEFAULT_REGION
  --list-scenes           列出所有预设场景
  -h, --help              显示帮助

预设场景:
  ─────────────────────────────────────────────────────────────
  基础建站
  ─────────────────────────────────────────────────────────────
  blog-small              个人博客/小型网站 (日PV < 5000)
  blog-medium             中型博客/企业官网 (日PV 5000-50000)
  
  ─────────────────────────────────────────────────────────────
  Web 应用
  ─────────────────────────────────────────────────────────────
  web-small               小型 Web 应用 (日PV < 10000)
  web-medium              中型 Web 应用 (日PV 10000-100000)
  web-large               大型 Web 应用 (日PV > 100000)
  
  ─────────────────────────────────────────────────────────────
  API 服务
  ─────────────────────────────────────────────────────────────
  api-small               小型 API 服务 (QPS < 100)
  api-medium              中型 API 服务 (QPS 100-1000)
  api-large               大型 API 服务 (QPS > 1000)
  
  ─────────────────────────────────────────────────────────────
  AI 场景
  ─────────────────────────────────────────────────────────────
  ai-inference-small      小型 AI 推理 (模型 < 3B 参数)
  ai-inference-medium     中型 AI 推理 (模型 3-13B 参数)
  ai-inference-large      大型 AI 推理集群 (模型 > 13B)
  ai-training             AI 模型训练/微调
  
  ─────────────────────────────────────────────────────────────
  电商平台
  ─────────────────────────────────────────────────────────────
  ecommerce-small         小型电商网站 (日订单 < 1000)
  ecommerce-medium        中型电商平台 (日订单 1000-10000)
  ecommerce-large         大型电商/大促场景 (日订单 > 10000)
  
  ─────────────────────────────────────────────────────────────
  视频直播
  ─────────────────────────────────────────────────────────────
  video-transcode         视频转码服务
  live-streaming-small    小型直播平台 (< 1000 并发)
  live-streaming-medium   中型直播平台 (1000-10000 并发)
  live-streaming-large    大型直播平台 (> 10000 并发)
  
  ─────────────────────────────────────────────────────────────
  游戏服务器
  ─────────────────────────────────────────────────────────────
  game-dev                游戏开发测试服
  game-small              小型游戏服 (< 500 在线)
  game-medium             中型游戏服 (500-5000 在线)
  game-large              大型游戏服 (> 5000 在线)
  
  ─────────────────────────────────────────────────────────────
  物联网
  ─────────────────────────────────────────────────────────────
  iot-gateway             IoT 网关/边缘计算
  iot-platform-small      小型物联网平台 (< 10000 设备)
  iot-platform-medium     中型物联网平台 (10000-100000 设备)
  iot-platform-large      大型物联网平台 (> 100000 设备)
  
  ─────────────────────────────────────────────────────────────
  大数据
  ─────────────────────────────────────────────────────────────
  bigdata-node            大数据计算节点 (Spark/Flink)
  bigdata-storage         大数据存储节点 (HDFS/HBase)
  bigdata-master          大数据集群主节点
  data-warehouse          数据仓库 (ClickHouse/Doris)
  
  ─────────────────────────────────────────────────────────────
  金融交易
  ─────────────────────────────────────────────────────────────
  fintech-trading         金融交易系统 (低延迟)
  fintech-risk            风控系统
  fintech-settlement      清算结算系统
  
  ─────────────────────────────────────────────────────────────
  数据库
  ─────────────────────────────────────────────────────────────
  database-small          小型数据库 (< 10GB)
  database-medium         中型数据库 (10-100GB)
  database-large          大型数据库 (> 100GB)
  
  ─────────────────────────────────────────────────────────────
  通用
  ─────────────────────────────────────────────────────────────
  dev                     开发测试环境
  
示例:
  $(basename "$0") --scene ai-inference-medium
  $(basename "$0") --scene ecommerce-large --region ap-shanghai
  $(basename "$0") --list-scenes
EOF
}

list_scenes() {
    cat <<EOF

════════════════════════════════════════════════════════════════════════════════
                           可用场景列表
════════════════════════════════════════════════════════════════════════════════

【基础建站】
场景ID              适用场景                        智能均衡方案
──────────────────────────────────────────────────────────────────────────────
blog-small          个人博客 (日PV<5K)              1核1G
blog-medium         中型博客 (日PV 5K-50K)          2核4G

【Web 应用】
──────────────────────────────────────────────────────────────────────────────
web-small           小型Web (日PV<10K)              2核2G
web-medium          中型Web (日PV 10K-100K)         4核8G
web-large           大型Web (日PV>100K)             8核16G

【API 服务】
──────────────────────────────────────────────────────────────────────────────
api-small           小型API (QPS<100)               2核4G
api-medium          中型API (QPS 100-1000)          4核8G
api-large           大型API (QPS>1000)              8核16G

【AI 推理/训练】
──────────────────────────────────────────────────────────────────────────────
ai-inference-small  小型推理 (模型<3B)              4核16G
ai-inference-medium 中型推理 (模型3-13B)            8核32G
ai-inference-large  大型推理集群 (模型>13B)         16核64G / GPU
ai-training         模型训练/微调                   GPU 实例

【电商平台】
──────────────────────────────────────────────────────────────────────────────
ecommerce-small     小型电商 (日订单<1K)            2核4G
ecommerce-medium    中型电商 (日订单1K-10K)         4核8G
ecommerce-large     大型电商/大促 (日订单>10K)      8核16G+

【视频直播】
──────────────────────────────────────────────────────────────────────────────
video-transcode     视频转码服务                    8核16G
live-streaming-small小型直播 (<1K并发)              4核8G
live-streaming-medium中型直播 (1K-10K并发)          8核16G
live-streaming-large大型直播 (>10K并发)             16核32G

【游戏服务器】
──────────────────────────────────────────────────────────────────────────────
game-dev            游戏开发测试服                  2核4G
game-small          小型游戏服 (<500在线)           4核8G
game-medium         中型游戏服 (500-5000在线)       8核16G
game-large          大型游戏服 (>5000在线)          16核32G

【物联网】
──────────────────────────────────────────────────────────────────────────────
iot-gateway         IoT网关/边缘计算                2核4G
iot-platform-small  小型IoT (<10K设备)              4核8G
iot-platform-medium 中型IoT (10K-100K设备)          8核16G
iot-platform-large  大型IoT (>100K设备)             16核32G

【大数据】
──────────────────────────────────────────────────────────────────────────────
bigdata-node        计算节点 (Spark/Flink)          8核32G
bigdata-storage     存储节点 (HDFS/HBase)           4核16G + 大容量盘
bigdata-master      集群主节点                      4核8G
data-warehouse      数据仓库 (ClickHouse)           16核64G

【金融交易】
──────────────────────────────────────────────────────────────────────────────
fintech-trading     交易系统 (低延迟)               8核16G
fintech-risk        风控系统                        8核32G
fintech-settlement  清算结算                        4核16G

【数据库】
──────────────────────────────────────────────────────────────────────────────
database-small      小型数据库 (<10GB)              2核4G + 50G
database-medium     中型数据库 (10-100GB)           4核16G + 200G
database-large      大型数据库 (>100GB)             8核32G + 500G

【通用】
──────────────────────────────────────────────────────────────────────────────
dev                 开发测试环境                    2核2G

════════════════════════════════════════════════════════════════════════════════

使用: $(basename "$0") --scene <场景ID>

EOF
}

#=============================================================================
# 场景配置定义
# 每个场景定义三套方案：经济实惠、智能均衡、性能旗舰
#=============================================================================

get_scene_config() {
    local scene="$1"
    
    # 公共变量
    SCENE_NAME=""
    SCENE_DESC=""
    AI_REASON=""
    
    # 经济实惠方案
    ECO_CPU=0 ECO_MEM=0 ECO_DISK=20 ECO_DATA_DISK="" ECO_FAMILIES="SA2 S5"
    # 智能均衡方案
    BAL_CPU=0 BAL_MEM=0 BAL_DISK=40 BAL_DATA_DISK="" BAL_FAMILIES="S5 SA3"
    # 性能旗舰方案
    PRO_CPU=0 PRO_MEM=0 PRO_DISK=50 PRO_DATA_DISK="" PRO_FAMILIES="S6 S5"
    
    REC_PLATFORM="TencentOS"
    
    case "$scene" in
        #=====================================================================
        # 基础建站
        #=====================================================================
        blog-small)
            SCENE_NAME="个人博客/小型网站"
            SCENE_DESC="适合日 PV 5000 以下的个人博客、小型展示网站、个人作品集"
            AI_REASON="个人博客流量较低，主要消耗在静态资源和轻量级动态请求。1核1G 可满足日常访问，预留 2 核可应对流量波动。"
            # 经济实惠
            ECO_CPU=1 ECO_MEM=1 ECO_DISK=20 ECO_FAMILIES="SA2 SA3"
            # 智能均衡
            BAL_CPU=1 BAL_MEM=2 BAL_DISK=30 BAL_FAMILIES="SA2 S5"
            # 性能旗舰
            PRO_CPU=2 PRO_MEM=4 PRO_DISK=40 PRO_FAMILIES="S5 S6"
            ;;
        blog-medium)
            SCENE_NAME="中型博客/企业官网"
            SCENE_DESC="适合日 PV 5000-50000 的博客、企业官网、小型电商展示站"
            AI_REASON="中型博客需处理更多并发请求，可能运行 WordPress + MySQL，2核4G 是性价比最优配置。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_FAMILIES="S5 S6"
            ;;
            
        #=====================================================================
        # Web 应用
        #=====================================================================
        web-small)
            SCENE_NAME="小型 Web 应用"
            SCENE_DESC="适合日 PV 10000 以下的 Web 应用、小程序后端、内部管理系统"
            AI_REASON="小型 Web 应用需要运行 Web 服务器 + 应用进程，2核2G 可满足轻量级业务，4核为性能储备。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_FAMILIES="S5 S6"
            ;;
        web-medium)
            SCENE_NAME="中型 Web 应用"
            SCENE_DESC="适合日 PV 10000-100000 的 Web 应用、API 网关、SaaS 服务"
            AI_REASON="中型 Web 应用并发量增加，需要更多内存缓存和 CPU 处理请求，4核8G 可支撑数百并发连接。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=40 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S6 S5"
            ;;
        web-large)
            SCENE_NAME="大型 Web 应用"
            SCENE_DESC="适合日 PV 10 万以上的高并发 Web 应用、核心业务系统"
            AI_REASON="高并发场景对 CPU 和网络吞吐要求高，8核16G 可处理千级并发，建议配合负载均衡横向扩展。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=100 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=200 PRO_FAMILIES="S6 S5"
            ;;
            
        #=====================================================================
        # API 服务
        #=====================================================================
        api-small)
            SCENE_NAME="小型 API 服务"
            SCENE_DESC="适合 QPS 100 以下的 API 服务、微服务节点、Webhook 服务"
            AI_REASON="API 服务主要消耗 CPU 处理请求，内存用于维护连接池。2核4G 可满足百级 QPS。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_FAMILIES="S5 S6"
            ;;
        api-medium)
            SCENE_NAME="中型 API 服务"
            SCENE_DESC="适合 QPS 100-1000 的 API 服务、中型微服务集群"
            AI_REASON="中等流量 API 需要更多 CPU 核心并行处理请求，8G 内存可维护更多并发连接和本地缓存。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=40 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_FAMILIES="S6 S5"
            ;;
        api-large)
            SCENE_NAME="大型 API 服务"
            SCENE_DESC="适合 QPS 1000 以上的核心 API 服务、API 网关"
            AI_REASON="高 QPS 场景需要高主频 CPU 和充足内存，8核16G 可支撑千级 QPS，建议多节点负载均衡。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S6 S5"
            ;;
            
        #=====================================================================
        # AI 场景
        #=====================================================================
        ai-inference-small)
            SCENE_NAME="小型 AI 推理"
            SCENE_DESC="适合 3B 参数以下模型推理（如 BERT、小型 LLM）"
            AI_REASON="小模型推理主要消耗内存加载模型权重，16G 可运行 3B 以下模型。CPU 推理延迟较高但成本低。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="S5 M5"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="M5 S6"
            ;;
        ai-inference-medium)
            SCENE_NAME="中型 AI 推理"
            SCENE_DESC="适合 3-13B 参数模型推理（如 LLaMA-7B、ChatGLM-6B）"
            AI_REASON="7B 模型约需 14G 显存或 28G 内存（CPU推理），32G 内存可运行量化后的 7B 模型，64G 可运行 13B。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 M5"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="M5 S6"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="M5 M6"
            ;;
        ai-inference-large)
            SCENE_NAME="大型 AI 推理集群"
            SCENE_DESC="适合 13B+ 参数模型推理（如 LLaMA-70B、GPT 类模型）"
            AI_REASON="大模型推理强烈建议使用 GPU 实例。CPU 方案需 128G+ 内存，仅适合对延迟不敏感的离线任务。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=8 ECO_MEM=32 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="M5 S6"
            BAL_CPU=16 BAL_MEM=64 BAL_DISK=100 BAL_DATA_DISK=500 BAL_FAMILIES="M5 M6"
            PRO_CPU=32 PRO_MEM=128 PRO_DISK=100 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;
        ai-training)
            SCENE_NAME="AI 模型训练/微调"
            SCENE_DESC="适合模型微调、小规模训练任务"
            AI_REASON="模型训练需要大量算力，强烈建议使用 GPU 实例。CPU 实例仅适合数据预处理和小规模实验。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=8 ECO_MEM=32 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="M5 S6"
            BAL_CPU=16 BAL_MEM=64 BAL_DISK=100 BAL_DATA_DISK=500 BAL_FAMILIES="M5 M6"
            PRO_CPU=32 PRO_MEM=128 PRO_DISK=100 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;
            
        #=====================================================================
        # 电商平台
        #=====================================================================
        ecommerce-small)
            SCENE_NAME="小型电商网站"
            SCENE_DESC="适合日订单 1000 以下的小型电商、独立站"
            AI_REASON="小型电商需运行商城系统 + 数据库，2核4G 可支撑千级日订单，建议数据库独立部署。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        ecommerce-medium)
            SCENE_NAME="中型电商平台"
            SCENE_DESC="适合日订单 1000-10000 的电商平台"
            AI_REASON="中型电商高峰期并发较高，4核8G 可支撑数百并发下单，建议应用和数据库分离部署。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=50 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=100 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=200 PRO_FAMILIES="S6 S5"
            ;;
        ecommerce-large)
            SCENE_NAME="大型电商/大促场景"
            SCENE_DESC="适合日订单 10000 以上或大促期间的电商平台"
            AI_REASON="大促场景流量可能瞬间暴增 10 倍，需要充足的 CPU 和内存应对秒杀场景，建议预留 50% 资源余量。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
            
        #=====================================================================
        # 视频直播
        #=====================================================================
        video-transcode)
            SCENE_NAME="视频转码服务"
            SCENE_DESC="适合视频转码、格式转换、短视频处理"
            AI_REASON="视频转码是 CPU 密集型任务，核心数直接影响并行转码路数。8核可同时处理 4-8 路转码。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="C6 S5"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="C6 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="C6 S6"
            ;;
        live-streaming-small)
            SCENE_NAME="小型直播平台"
            SCENE_DESC="适合并发观众 1000 以下的直播服务"
            AI_REASON="小型直播主要消耗带宽和连接数，4核8G 可处理千级并发连接。建议配合 CDN 分发流量。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        live-streaming-medium)
            SCENE_NAME="中型直播平台"
            SCENE_DESC="适合并发观众 1000-10000 的直播服务"
            AI_REASON="万级并发需要高性能网络和连接管理，8核16G 配合边缘节点可支撑中型直播业务。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="S6 S5"
            ;;
        live-streaming-large)
            SCENE_NAME="大型直播平台"
            SCENE_DESC="适合并发观众 10000 以上的大型直播、赛事直播"
            AI_REASON="大型直播需要分布式架构，单节点主要做源站和调度。16核32G 可做核心源站，流量通过 CDN 分发。"
            ECO_CPU=8 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="S5 S6"
            BAL_CPU=16 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=1000 BAL_FAMILIES="S6 S5"
            PRO_CPU=32 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=2000 PRO_FAMILIES="S6 S5"
            ;;
            
        #=====================================================================
        # 游戏服务器
        #=====================================================================
        game-dev)
            SCENE_NAME="游戏开发测试服"
            SCENE_DESC="适合游戏开发、联调测试"
            AI_REASON="测试服不需要高配置，2核4G 可运行单个游戏服务端进程，满足小团队联调需求。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        game-small)
            SCENE_NAME="小型游戏服"
            SCENE_DESC="适合同时在线 500 以下的游戏服务器"
            AI_REASON="小型游戏服主要消耗 CPU（逻辑运算）和内存（玩家状态），4核8G 可支撑数百在线玩家。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=50 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=100 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=200 PRO_FAMILIES="S6 S5"
            ;;
        game-medium)
            SCENE_NAME="中型游戏服"
            SCENE_DESC="适合同时在线 500-5000 的游戏服务器"
            AI_REASON="中型游戏服需要更高主频 CPU 保证游戏逻辑流畅，8核16G 可支撑千级同时在线。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        game-large)
            SCENE_NAME="大型游戏服"
            SCENE_DESC="适合同时在线 5000 以上的大型游戏服务器"
            AI_REASON="大型游戏服需要高性能 CPU 和大内存，16核32G 可支撑数千玩家。建议根据游戏类型选择多节点分布式部署。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=8 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 S6"
            BAL_CPU=16 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S6 S5"
            PRO_CPU=32 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=1000 PRO_FAMILIES="S6 S5"
            ;;
            
        #=====================================================================
        # 物联网
        #=====================================================================
        iot-gateway)
            SCENE_NAME="IoT 网关/边缘计算"
            SCENE_DESC="适合物联网网关、边缘计算节点、协议转换"
            AI_REASON="IoT 网关主要做协议转换和数据汇聚，2核4G 可处理万级设备连接。消息吞吐才是关键。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        iot-platform-small)
            SCENE_NAME="小型物联网平台"
            SCENE_DESC="适合设备数 10000 以下的物联网平台"
            AI_REASON="小型 IoT 平台需处理设备连接和消息存储，4核8G 可支撑万级设备长连接。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        iot-platform-medium)
            SCENE_NAME="中型物联网平台"
            SCENE_DESC="适合设备数 10000-100000 的物联网平台"
            AI_REASON="10 万设备并发需要高性能网络栈和消息队列，8核16G 是单节点的合理上限，建议集群部署。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="S6 S5"
            ;;
        iot-platform-large)
            SCENE_NAME="大型物联网平台"
            SCENE_DESC="适合设备数 100000 以上的大型物联网平台"
            AI_REASON="百万级设备必须分布式架构，单节点做接入层和处理节点。16核32G 可作为核心处理节点。"
            ECO_CPU=8 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="S5 S6"
            BAL_CPU=16 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=1000 BAL_FAMILIES="S6 S5"
            PRO_CPU=32 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=2000 PRO_FAMILIES="S6 S5"
            ;;
            
        #=====================================================================
        # 大数据
        #=====================================================================
        bigdata-node)
            SCENE_NAME="大数据计算节点"
            SCENE_DESC="适合 Spark、Flink、MapReduce 计算任务"
            AI_REASON="大数据计算是 CPU 和内存密集型，8核32G 是单节点的常见配置，内存用于 Shuffle 和缓存。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="M5 S5"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="M5 D3"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;
        bigdata-storage)
            SCENE_NAME="大数据存储节点"
            SCENE_DESC="适合 HDFS DataNode、HBase RegionServer"
            AI_REASON="存储节点关键是磁盘容量和 IO 性能，4核16G + 大容量本地盘是常见配置。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="D3 S5"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=1000 BAL_FAMILIES="D3 M5"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=2000 PRO_FAMILIES="D3 M5"
            ;;
        bigdata-master)
            SCENE_NAME="大数据集群主节点"
            SCENE_DESC="适合 YARN ResourceManager、HDFS NameNode、HBase Master"
            AI_REASON="主节点主要负责调度和元数据管理，不需要特别高配置，但要求高可用。4核8G 足够。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        data-warehouse)
            SCENE_NAME="数据仓库"
            SCENE_DESC="适合 ClickHouse、Doris、StarRocks 等 OLAP 数据库"
            AI_REASON="OLAP 查询需要大量内存做向量化计算，16核64G 可支撑中等规模数据仓库，配合 SSD 提升查询性能。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=8 ECO_MEM=32 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="M5 S6"
            BAL_CPU=16 BAL_MEM=64 BAL_DISK=100 BAL_DATA_DISK=1000 BAL_FAMILIES="M5 M6"
            PRO_CPU=32 PRO_MEM=128 PRO_DISK=100 PRO_DATA_DISK=2000 PRO_FAMILIES="M6 M5"
            ;;
            
        #=====================================================================
        # 金融交易
        #=====================================================================
        fintech-trading)
            SCENE_NAME="金融交易系统"
            SCENE_DESC="适合证券交易、量化交易、订单撮合系统"
            AI_REASON="交易系统对延迟极度敏感，需要高主频 CPU 和低延迟网络。8核16G 配合高性能 SSD 可实现微秒级响应。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 S6"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S6 S5"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=100 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        fintech-risk)
            SCENE_NAME="风控系统"
            SCENE_DESC="适合实时风控、反欺诈、信用评估系统"
            AI_REASON="风控系统需要快速完成复杂规则计算，8核32G 可支撑高频风控请求，内存用于缓存规则和特征。"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="M5 S5"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="M5 S6"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=500 PRO_FAMILIES="M6 M5"
            ;;
        fintech-settlement)
            SCENE_NAME="清算结算系统"
            SCENE_DESC="适合支付清算、账务处理、对账系统"
            AI_REASON="清算系统批量处理能力要求高，4核16G 可满足日终批量清算，建议配合高可用部署。"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 M5"
            ;;
            
        #=====================================================================
        # 数据库
        #=====================================================================
        database-small)
            SCENE_NAME="小型数据库"
            SCENE_DESC="适合数据量 10GB 以下的 MySQL/PostgreSQL/MongoDB"
            AI_REASON="小型数据库主要消耗内存做缓存，2核4G + 50G SSD 可满足小型业务需求。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_DATA_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        database-medium)
            SCENE_NAME="中型数据库"
            SCENE_DESC="适合数据量 10-100GB 的数据库，需要较好的 IO 性能"
            AI_REASON="中型数据库需要更大内存提升 Buffer Pool 命中率，4核16G + 200G SSD 是性价比配置。"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 M5"
            ;;
        database-large)
            SCENE_NAME="大型数据库"
            SCENE_DESC="适合数据量 100GB 以上的高性能数据库"
            AI_REASON="大型数据库需要充足内存和高 IOPS 磁盘，8核32G + 500G 高性能 SSD 可支撑高并发读写。"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 S6"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S6 M5"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;
            
        #=====================================================================
        # 通用
        #=====================================================================
        dev)
            SCENE_NAME="开发测试环境"
            SCENE_DESC="适合开发、测试、学习用途"
            AI_REASON="开发环境不需要高配置，2核2G 足够运行常见开发工具和服务。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=1 ECO_MEM=1 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=2 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=2 PRO_MEM=4 PRO_DISK=50 PRO_FAMILIES="S5 SA3"
            ;;
            
        *)
            error "未知场景: $scene"
            echo "使用 --list-scenes 查看可用场景"
            exit 1
            ;;
    esac
}

#=============================================================================
# 资源查询函数
#=============================================================================

# 查找可用实例类型
find_instance_type() {
    local region="$1" zone="$2" cpu="$3" mem="$4" families="$5"
    
    for family in $families; do
        local result
        result=$(tccli cvm DescribeInstanceTypeConfigs --region "$region" \
            --Filters "[{\"Name\":\"zone\",\"Values\":[\"$zone\"]},{\"Name\":\"instance-family\",\"Values\":[\"$family\"]}]" 2>/dev/null || echo '{"InstanceTypeConfigSet":[]}')
        
        local instance_type
        instance_type=$(echo "$result" | jq -r --argjson cpu "$cpu" --argjson mem "$mem" \
            '.InstanceTypeConfigSet[] | select(.CPU == $cpu and .Memory == $mem) | .InstanceType' | head -1)
        
        if [[ -n "$instance_type" ]]; then
            echo "$instance_type"
            return 0
        fi
    done
    
    # 尝试找接近的配置
    for family in $families; do
        local result
        result=$(tccli cvm DescribeInstanceTypeConfigs --region "$region" \
            --Filters "[{\"Name\":\"zone\",\"Values\":[\"$zone\"]},{\"Name\":\"instance-family\",\"Values\":[\"$family\"]}]" 2>/dev/null || echo '{"InstanceTypeConfigSet":[]}')
        
        local instance_type
        instance_type=$(echo "$result" | jq -r --argjson cpu "$cpu" --argjson mem "$mem" \
            '[.InstanceTypeConfigSet[] | select(.CPU >= $cpu and .Memory >= $mem)] | sort_by(.CPU, .Memory) | .[0].InstanceType // empty')
        
        if [[ -n "$instance_type" ]]; then
            echo "$instance_type"
            return 0
        fi
    done
    
    return 1
}

# 查找可用镜像
find_image() {
    local region="$1" instance_type="$2" platform="$3"
    
    local result
    result=$(tccli cvm DescribeImages --region "$region" \
        --InstanceType "$instance_type" \
        --Filters "[{\"Name\":\"image-type\",\"Values\":[\"PUBLIC_IMAGE\"]},{\"Name\":\"platform\",\"Values\":[\"$platform\"]}]" \
        --Limit 10 2>/dev/null || echo '{"ImageSet":[]}')
    
    local image_id
    image_id=$(echo "$result" | jq -r '.ImageSet[0].ImageId // empty')
    
    if [[ -n "$image_id" ]]; then
        local image_name
        image_name=$(echo "$result" | jq -r '.ImageSet[0].ImageName // empty')
        echo "$image_id|$image_name"
        return 0
    fi
    
    return 1
}

# 获取默认 VPC 和子网
get_default_vpc() {
    local region="$1" zone="$2"
    
    local vpc_result
    vpc_result=$(tccli vpc DescribeVpcs --region "$region" --Limit 10 2>/dev/null || echo '{"VpcSet":[]}')
    local vpc_id
    vpc_id=$(echo "$vpc_result" | jq -r '.VpcSet[0].VpcId // empty')
    
    [[ -z "$vpc_id" ]] && return 1
    
    local subnet_result
    subnet_result=$(tccli vpc DescribeSubnets --region "$region" \
        --Filters "[{\"Name\":\"vpc-id\",\"Values\":[\"$vpc_id\"]},{\"Name\":\"zone\",\"Values\":[\"$zone\"]}]" 2>/dev/null || echo '{"SubnetSet":[]}')
    local subnet_id
    subnet_id=$(echo "$subnet_result" | jq -r '.SubnetSet[0].SubnetId // empty')
    
    [[ -z "$subnet_id" ]] && return 1
    
    echo "$vpc_id|$subnet_id"
}

# 获取默认安全组
get_default_sg() {
    local region="$1"
    
    local sg_result
    sg_result=$(tccli vpc DescribeSecurityGroups --region "$region" --Limit 10 2>/dev/null || echo '{"SecurityGroupSet":[]}')
    local sg_id
    sg_id=$(echo "$sg_result" | jq -r '.SecurityGroupSet[0].SecurityGroupId // empty')
    
    [[ -z "$sg_id" ]] && return 1
    echo "$sg_id"
}

# 获取可用区
get_available_zone() {
    local region="$1"
    
    local zone_result
    zone_result=$(tccli cvm DescribeZones --region "$region" 2>/dev/null || echo '{"ZoneSet":[]}')
    local zone
    zone=$(echo "$zone_result" | jq -r '.ZoneSet[] | select(.ZoneState == "AVAILABLE") | .Zone' | head -1)
    
    [[ -z "$zone" ]] && return 1
    echo "$zone"
}

# 询价函数
inquiry_price() {
    local region="$1"
    local zone="$2"
    local instance_type="$3"
    local image_id="$4"
    local disk_size="$5"
    local data_disk_size="$6"
    
    local data_disk_param=""
    if [[ -n "$data_disk_size" && "$data_disk_size" != "0" ]]; then
        data_disk_param="--DataDisks [{\"DiskType\":\"CLOUD_PREMIUM\",\"DiskSize\":$data_disk_size}]"
    fi
    
    local result
    result=$(tccli cvm InquiryPriceRunInstances --region "$region" \
        --Placement "{\"Zone\":\"$zone\"}" \
        --ImageId "$image_id" \
        --InstanceType "$instance_type" \
        --SystemDisk "{\"DiskType\":\"CLOUD_PREMIUM\",\"DiskSize\":$disk_size}" \
        --InternetAccessible "{\"InternetChargeType\":\"TRAFFIC_POSTPAID_BY_HOUR\",\"InternetMaxBandwidthOut\":10,\"PublicIpAssigned\":true}" \
        $data_disk_param 2>/dev/null || echo '{"Price":{}}')
    
    # 获取按量付费小时价格
    local hour_price
    hour_price=$(echo "$result" | jq -r '.Price.InstancePrice.UnitPriceDiscount // .Price.InstancePrice.UnitPrice // 0')
    
    # 计算月费（按 720 小时/月）
    if [[ "$hour_price" != "0" && "$hour_price" != "null" ]]; then
        local month_price
        month_price=$(echo "scale=2; $hour_price * 720" | bc)
        echo "$hour_price|$month_price"
    else
        echo "0|0"
    fi
}

#=============================================================================
# 方案查找和展示
#=============================================================================

# 查找单个方案的配置
find_plan_config() {
    local region="$1" zone="$2" cpu="$3" mem="$4" families="$5" disk="$6" data_disk="$7"
    
    local instance_type
    instance_type=$(find_instance_type "$region" "$zone" "$cpu" "$mem" "$families")
    
    if [[ -z "$instance_type" ]]; then
        echo ""
        return 1
    fi
    
    # 获取实际的 CPU 和内存
    local type_info
    type_info=$(tccli cvm DescribeInstanceTypeConfigs --region "$region" \
        --Filters "[{\"Name\":\"instance-type\",\"Values\":[\"$instance_type\"]}]" 2>/dev/null || echo '{"InstanceTypeConfigSet":[]}')
    
    local actual_cpu actual_mem
    actual_cpu=$(echo "$type_info" | jq -r '.InstanceTypeConfigSet[0].CPU // 0')
    actual_mem=$(echo "$type_info" | jq -r '.InstanceTypeConfigSet[0].Memory // 0')
    
    echo "$instance_type|$actual_cpu|$actual_mem|$disk|$data_disk"
}

# 显示方案对比表
show_plans_comparison() {
    local eco_info="$1" bal_info="$2" pro_info="$3"
    local eco_price="$4" bal_price="$5" pro_price="$6"
    local image_id="$7" image_name="$8"
    
    # 解析方案信息
    local eco_type eco_cpu eco_mem eco_disk eco_data
    local bal_type bal_cpu bal_mem bal_disk bal_data
    local pro_type pro_cpu pro_mem pro_disk pro_data
    
    IFS='|' read -r eco_type eco_cpu eco_mem eco_disk eco_data <<< "$eco_info"
    IFS='|' read -r bal_type bal_cpu bal_mem bal_disk bal_data <<< "$bal_info"
    IFS='|' read -r pro_type pro_cpu pro_mem pro_disk pro_data <<< "$pro_info"
    
    local eco_hour eco_month bal_hour bal_month pro_hour pro_month
    IFS='|' read -r eco_hour eco_month <<< "$eco_price"
    IFS='|' read -r bal_hour bal_month <<< "$bal_price"
    IFS='|' read -r pro_hour pro_month <<< "$pro_price"
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "                              方案对比"
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    printf "%-20s %-20s %-20s %-20s\n" "配置项" "💰 经济实惠" "⚖️  智能均衡 (推荐)" "🚀 性能旗舰"
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "%-20s %-20s %-20s %-20s\n" "实例类型" "$eco_type" "$bal_type" "$pro_type"
    printf "%-20s %-20s %-20s %-20s\n" "CPU" "${eco_cpu}核" "${bal_cpu}核" "${pro_cpu}核"
    printf "%-20s %-20s %-20s %-20s\n" "内存" "${eco_mem}GB" "${bal_mem}GB" "${pro_mem}GB"
    printf "%-20s %-20s %-20s %-20s\n" "系统盘" "${eco_disk}GB" "${bal_disk}GB" "${pro_disk}GB"
    if [[ -n "$eco_data" || -n "$bal_data" || -n "$pro_data" ]]; then
        printf "%-20s %-20s %-20s %-20s\n" "数据盘" "${eco_data:-无}${eco_data:+GB}" "${bal_data:-无}${bal_data:+GB}" "${pro_data:-无}${pro_data:+GB}"
    fi
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "%-20s %-20s %-20s %-20s\n" "小时价格" "¥${eco_hour}/小时" "¥${bal_hour}/小时" "¥${pro_hour}/小时"
    printf "%-20s %-20s %-20s %-20s\n" "预估月费" "≈¥${eco_month}/月" "≈¥${bal_month}/月" "≈¥${pro_month}/月"
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "镜像: $image_id ($image_name)"
    echo ""
}

#=============================================================================
# 主流程
#=============================================================================

check_api_prerequisites
load_defaults

SCENE="" LIST_SCENES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scene) SCENE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --list-scenes) LIST_SCENES=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知选项: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$LIST_SCENES" == "true" ]]; then
    list_scenes
    exit 0
fi

if [[ -z "$SCENE" ]]; then
    error "请指定场景: --scene <scene>"
    echo ""
    list_scenes
    exit 1
fi

validate_region "$REGION"

# 获取场景配置
get_scene_config "$SCENE"

echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "                              场景分析"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""
echo "📌 场景: $SCENE_NAME"
echo ""
echo "📝 说明: $SCENE_DESC"
echo ""
echo "🤖 AI 推荐理由:"
echo "   $AI_REASON"
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""

info "正在查询可用资源 (地域: $REGION)..."

# Step 1: 获取可用区
ZONE=$(get_available_zone "$REGION")
if [[ -z "$ZONE" ]]; then
    error "未找到可用区"
    exit 1
fi
success "可用区: $ZONE"

# Step 2: 查找三种方案的实例类型
info "正在查询三种方案的实例配置..."

ECO_INFO=$(find_plan_config "$REGION" "$ZONE" "$ECO_CPU" "$ECO_MEM" "$ECO_FAMILIES" "$ECO_DISK" "$ECO_DATA_DISK")
BAL_INFO=$(find_plan_config "$REGION" "$ZONE" "$BAL_CPU" "$BAL_MEM" "$BAL_FAMILIES" "$BAL_DISK" "$BAL_DATA_DISK")
PRO_INFO=$(find_plan_config "$REGION" "$ZONE" "$PRO_CPU" "$PRO_MEM" "$PRO_FAMILIES" "$PRO_DISK" "$PRO_DATA_DISK")

# 检查是否至少有一个方案可用
if [[ -z "$ECO_INFO" && -z "$BAL_INFO" && -z "$PRO_INFO" ]]; then
    error "未找到合适的实例类型"
    echo "请尝试其他地域或手动选择配置"
    exit 1
fi

# Step 3: 查找镜像（使用均衡方案的实例类型查找）
BAL_TYPE=$(echo "$BAL_INFO" | cut -d'|' -f1)
if [[ -z "$BAL_TYPE" ]]; then
    # 如果均衡方案不可用，尝试经济或性能方案
    BAL_TYPE=$(echo "$ECO_INFO" | cut -d'|' -f1)
    [[ -z "$BAL_TYPE" ]] && BAL_TYPE=$(echo "$PRO_INFO" | cut -d'|' -f1)
fi

IMAGE_INFO=$(find_image "$REGION" "$BAL_TYPE" "$REC_PLATFORM")
if [[ -z "$IMAGE_INFO" ]]; then
    error "未找到兼容镜像"
    exit 1
fi
IMAGE_ID=$(echo "$IMAGE_INFO" | cut -d'|' -f1)
IMAGE_NAME=$(echo "$IMAGE_INFO" | cut -d'|' -f2)
success "镜像: $IMAGE_ID"

# Step 4: 获取网络配置
VPC_INFO=$(get_default_vpc "$REGION" "$ZONE")
if [[ -z "$VPC_INFO" ]]; then
    error "未找到可用的 VPC/子网"
    echo "请先创建 VPC 和子网"
    exit 1
fi
VPC_ID=$(echo "$VPC_INFO" | cut -d'|' -f1)
SUBNET_ID=$(echo "$VPC_INFO" | cut -d'|' -f2)
success "网络: $VPC_ID / $SUBNET_ID"

SG_ID=$(get_default_sg "$REGION")
if [[ -z "$SG_ID" ]]; then
    error "未找到安全组"
    exit 1
fi
success "安全组: $SG_ID"

# Step 5: 询价
info "正在查询实时价格..."

ECO_PRICE="0|0" BAL_PRICE="0|0" PRO_PRICE="0|0"

if [[ -n "$ECO_INFO" ]]; then
    ECO_TYPE=$(echo "$ECO_INFO" | cut -d'|' -f1)
    ECO_DISK_VAL=$(echo "$ECO_INFO" | cut -d'|' -f4)
    ECO_DATA_VAL=$(echo "$ECO_INFO" | cut -d'|' -f5)
    ECO_PRICE=$(inquiry_price "$REGION" "$ZONE" "$ECO_TYPE" "$IMAGE_ID" "$ECO_DISK_VAL" "$ECO_DATA_VAL")
fi

if [[ -n "$BAL_INFO" ]]; then
    BAL_TYPE=$(echo "$BAL_INFO" | cut -d'|' -f1)
    BAL_DISK_VAL=$(echo "$BAL_INFO" | cut -d'|' -f4)
    BAL_DATA_VAL=$(echo "$BAL_INFO" | cut -d'|' -f5)
    BAL_PRICE=$(inquiry_price "$REGION" "$ZONE" "$BAL_TYPE" "$IMAGE_ID" "$BAL_DISK_VAL" "$BAL_DATA_VAL")
fi

if [[ -n "$PRO_INFO" ]]; then
    PRO_TYPE=$(echo "$PRO_INFO" | cut -d'|' -f1)
    PRO_DISK_VAL=$(echo "$PRO_INFO" | cut -d'|' -f4)
    PRO_DATA_VAL=$(echo "$PRO_INFO" | cut -d'|' -f5)
    PRO_PRICE=$(inquiry_price "$REGION" "$ZONE" "$PRO_TYPE" "$IMAGE_ID" "$PRO_DISK_VAL" "$PRO_DATA_VAL")
fi

success "价格查询完成"

# Step 6: 显示方案对比
show_plans_comparison "$ECO_INFO" "$BAL_INFO" "$PRO_INFO" "$ECO_PRICE" "$BAL_PRICE" "$PRO_PRICE" "$IMAGE_ID" "$IMAGE_NAME"

# Step 7: 用户选择方案
echo "请选择方案:"
echo ""
[[ -n "$ECO_INFO" ]] && echo "  [1] 💰 经济实惠方案"
[[ -n "$BAL_INFO" ]] && echo "  [2] ⚖️  智能均衡方案 (推荐)"
[[ -n "$PRO_INFO" ]] && echo "  [3] 🚀 性能旗舰方案"
echo "  [0] 取消"
echo ""

read -p "请输入选择 [0-3]: " CHOICE

case "$CHOICE" in
    1)
        if [[ -z "$ECO_INFO" ]]; then
            error "经济实惠方案不可用"
            exit 1
        fi
        SELECTED_INFO="$ECO_INFO"
        SELECTED_NAME="经济实惠"
        ;;
    2)
        if [[ -z "$BAL_INFO" ]]; then
            error "智能均衡方案不可用"
            exit 1
        fi
        SELECTED_INFO="$BAL_INFO"
        SELECTED_NAME="智能均衡"
        ;;
    3)
        if [[ -z "$PRO_INFO" ]]; then
            error "性能旗舰方案不可用"
            exit 1
        fi
        SELECTED_INFO="$PRO_INFO"
        SELECTED_NAME="性能旗舰"
        ;;
    0|*)
        info "已取消"
        exit 0
        ;;
esac

# 解析选中方案
SELECTED_TYPE=$(echo "$SELECTED_INFO" | cut -d'|' -f1)
SELECTED_CPU=$(echo "$SELECTED_INFO" | cut -d'|' -f2)
SELECTED_MEM=$(echo "$SELECTED_INFO" | cut -d'|' -f3)
SELECTED_DISK=$(echo "$SELECTED_INFO" | cut -d'|' -f4)
SELECTED_DATA_DISK=$(echo "$SELECTED_INFO" | cut -d'|' -f5)

echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "                              确认创建"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""
echo "已选择: $SELECTED_NAME 方案"
echo ""
echo "  场景:       $SCENE_NAME"
echo "  地域:       $REGION"
echo "  可用区:     $ZONE"
echo "  实例类型:   $SELECTED_TYPE (${SELECTED_CPU}核${SELECTED_MEM}G)"
echo "  镜像:       $IMAGE_ID"
echo "  系统盘:     ${SELECTED_DISK}GB"
[[ -n "$SELECTED_DATA_DISK" ]] && echo "  数据盘:     ${SELECTED_DATA_DISK}GB"
echo "  网络:       $VPC_ID / $SUBNET_ID"
echo "  安全组:     $SG_ID"
echo "  计费模式:   按量付费"
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""

# 最终确认
confirm "确认创建实例？（这将产生费用）" || { info "已取消"; exit 0; }

# 构建创建命令
CREATE_ARGS="--region $REGION --zone $ZONE --instance-type $SELECTED_TYPE --image-id $IMAGE_ID --vpc-id $VPC_ID --subnet-id $SUBNET_ID --sg-id $SG_ID --disk-size $SELECTED_DISK"
[[ -n "$SELECTED_DATA_DISK" ]] && CREATE_ARGS="$CREATE_ARGS --data-disk-size $SELECTED_DATA_DISK"

# 调用创建脚本
echo ""
exec "$SCRIPT_DIR/create-instance.sh" $CREATE_ARGS
