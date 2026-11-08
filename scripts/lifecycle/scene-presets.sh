#!/bin/bash
# Static sizing starting points only; no API calls or capacity guarantees.
list_scenes() {
    cat <<EOF

════════════════════════════════════════════════════════════════════════════════
                           可用场景列表
════════════════════════════════════════════════════════════════════════════════

下列为均衡档的 CPU/主机内存筛选下限，不是最终规格或容量保证。
small/medium/large 表示逐步提高的资源预设；需用实际负载和延迟目标验证。
AI 场景默认筛选 GPU，但还需按模型、精度、上下文和批量核对 GPU 显存。

场景ID                    用途                         均衡档筛选下限
【基础建站】
──────────────────────────────────────────────────────────────────────────────
blog-small                个人博客/展示网站             1核2GiB
blog-medium               博客/企业官网                 2核4GiB

【Web 应用】
──────────────────────────────────────────────────────────────────────────────
web-small                 Web 应用起步                 2核4GiB
web-medium                Web 应用扩展                 4核8GiB
web-large                 核心 Web 业务节点            8核16GiB

【API 服务】
──────────────────────────────────────────────────────────────────────────────
api-small                 API 服务起步                 2核4GiB
api-medium                API 服务扩展                 4核8GiB
api-large                 核心 API/网关节点            8核16GiB

【AI 推理/训练】
──────────────────────────────────────────────────────────────────────────────
ai-inference-small        推理实验起步                 4核16GiB + GPU
ai-inference-medium       推理资源扩展                 8核32GiB + GPU
ai-inference-large        推理/分布式推理候选          16核64GiB + GPU
ai-training               训练/微调候选                16核64GiB + GPU

【电商平台】
──────────────────────────────────────────────────────────────────────────────
ecommerce-small           商城应用起步                 2核4GiB
ecommerce-medium          商城应用扩展                 4核8GiB
ecommerce-large           电商高峰/核心应用节点        8核16GiB

【视频直播】
──────────────────────────────────────────────────────────────────────────────
video-transcode           视频转码                     8核16GiB
live-streaming-small      直播服务起步                 4核8GiB
live-streaming-medium     直播服务扩展                 8核16GiB
live-streaming-large      直播源站/调度节点            16核32GiB

【游戏服务器】
──────────────────────────────────────────────────────────────────────────────
game-dev                  游戏开发测试                 2核4GiB
game-small                游戏服务起步                 4核8GiB
game-medium               游戏服务扩展                 8核16GiB
game-large                游戏服务较高资源档           16核32GiB

【物联网】
──────────────────────────────────────────────────────────────────────────────
iot-gateway               IoT 网关/边缘计算            2核4GiB
iot-platform-small        IoT 接入/处理起步            4核8GiB
iot-platform-medium       IoT 接入/处理扩展            8核16GiB
iot-platform-large        IoT 节点较高资源档           16核32GiB

【大数据】
──────────────────────────────────────────────────────────────────────────────
bigdata-node              Spark/Flink 计算节点         8核32GiB
bigdata-storage           HDFS/HBase 存储节点          4核16GiB
bigdata-master            集群主节点                   4核8GiB
data-warehouse            OLAP 数据仓库                16核64GiB

【金融交易】
──────────────────────────────────────────────────────────────────────────────
fintech-trading           交易应用/撮合节点            8核16GiB
fintech-risk              风控节点                     8核32GiB
fintech-settlement        清算/对账节点                4核16GiB

【数据库】
──────────────────────────────────────────────────────────────────────────────
database-small            数据库起步                   2核4GiB
database-medium           数据库扩展                   4核16GiB
database-large            数据库较高资源档             8核32GiB

【通用】
──────────────────────────────────────────────────────────────────────────────
dev                       开发测试                     2核2GiB

════════════════════════════════════════════════════════════════════════════════

使用: $(basename "$0") --scene <场景ID>
推荐时会查询实时售卖状态、兼容镜像和价格；最终候选可能高于筛选下限。
磁盘另有起步预设，需按数据、日志、备份及增长量调整；容量不能代表 IO 性能。

EOF
}

#=============================================================================
# 场景配置定义
# 每个场景定义三档筛选起点：经济、均衡、较高资源；不是性能保证。
# FAMILIES 保留兼容；当前推荐器按实时在售规格筛选，不按这些历史系列限定。
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
            SCENE_DESC="个人博客、展示网站和作品集的起步筛选档"
            AI_REASON="从应用和数据库的常驻内存、缓存方式及实测请求延迟判断配置；页面访问量不能直接换算为所需核数。"
            # 经济实惠
            ECO_CPU=1 ECO_MEM=1 ECO_DISK=20 ECO_FAMILIES="SA2 SA3"
            # 智能均衡
            BAL_CPU=1 BAL_MEM=2 BAL_DISK=30 BAL_FAMILIES="SA2 S5"
            # 性能旗舰
            PRO_CPU=2 PRO_MEM=4 PRO_DISK=40 PRO_FAMILIES="S5 S6"
            ;;
        blog-medium)
            SCENE_NAME="中型博客/企业官网"
            SCENE_DESC="博客、企业官网和内容管理系统的扩展筛选档"
            AI_REASON="WordPress、数据库和插件可能有不同的资源需求；用实际页面、缓存命中率及峰值请求压测后调整。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_FAMILIES="S5 S6"
            ;;

        #=====================================================================
        # Web 应用
        #=====================================================================
        web-small)
            SCENE_NAME="小型 Web 应用"
            SCENE_DESC="Web 应用、小程序后端和内部系统的起步筛选档"
            AI_REASON="先核对 Web 服务、应用进程及依赖服务的常驻内存，再用实际请求测量 CPU 使用率和响应延迟。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_FAMILIES="S5 S6"
            ;;
        web-medium)
            SCENE_NAME="中型 Web 应用"
            SCENE_DESC="Web 应用、API 网关和 SaaS 服务的扩展筛选档"
            AI_REASON="此档提高 CPU 和内存筛选下限；可承载并发量取决于请求逻辑、缓存、数据库及外部依赖，需要压测。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=40 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S6 S5"
            ;;
        web-large)
            SCENE_NAME="大型 Web 应用"
            SCENE_DESC="核心 Web 业务及多节点部署的较高资源筛选档"
            AI_REASON="根据实际峰值、延迟目标和依赖瓶颈评估单节点配置及横向扩展；本预设不代表已完成高并发容量规划。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=100 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=200 PRO_FAMILIES="S6 S5"
            ;;

        #=====================================================================
        # API 服务
        #=====================================================================
        api-small)
            SCENE_NAME="小型 API 服务"
            SCENE_DESC="API、微服务节点和 Webhook 的起步筛选档"
            AI_REASON="按实际请求逻辑、连接池和依赖延迟测量资源消耗；此预设不提供 QPS 保证。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_FAMILIES="S5 S6"
            ;;
        api-medium)
            SCENE_NAME="中型 API 服务"
            SCENE_DESC="API 服务及微服务节点的扩展筛选档"
            AI_REASON="核数和内存只是筛选条件；以真实请求组合、并发度、缓存命中率及尾延迟测试确定容量。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=40 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_FAMILIES="S6 S5"
            ;;
        api-large)
            SCENE_NAME="大型 API 服务"
            SCENE_DESC="核心 API 和 API 网关的较高资源筛选档"
            AI_REASON="先明确吞吐和延迟目标，再测试 CPU、网络及后端瓶颈；多节点扩展效果也需要验证。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S6 S5"
            ;;

        #=====================================================================
        # AI 场景
        #=====================================================================
        ai-inference-small)
            SCENE_NAME="小型 AI 推理"
            SCENE_DESC="AI 推理实验的起步筛选档，需单独核对 GPU 与显存"
            AI_REASON="CPU 和主机内存仅用于筛选候选，不能推导模型能否装入显存。需按模型、精度、上下文长度、批量和推理框架核对显存并实测。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="S5 M5"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="M5 S6"
            ;;
        ai-inference-medium)
            SCENE_NAME="中型 AI 推理"
            SCENE_DESC="AI 推理的扩展筛选档，需单独核对 GPU 与显存"
            AI_REASON="不能仅按参数量或主机内存判断模型容量；需核对权重、KV 缓存、运行时开销、GPU 型号和显存，并测试目标延迟。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 M5"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="M5 S6"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="M5 M6"
            ;;
        ai-inference-large)
            SCENE_NAME="大型 AI 推理集群"
            SCENE_DESC="AI 推理或分布式推理的较高资源筛选档"
            AI_REASON="此档不定义模型大小或集群容量。先计算目标模型的显存需求，再核对 GPU 数量、互联、框架兼容性并实测吞吐与延迟。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=8 ECO_MEM=32 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="M5 S6"
            BAL_CPU=16 BAL_MEM=64 BAL_DISK=100 BAL_DATA_DISK=500 BAL_FAMILIES="M5 M6"
            PRO_CPU=32 PRO_MEM=128 PRO_DISK=100 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;
        ai-training)
            SCENE_NAME="AI 模型训练/微调"
            SCENE_DESC="模型训练和微调的候选筛选档，需单独完成 GPU 选型"
            AI_REASON="训练显存受模型、优化器、精度、序列长度和批量等影响；主机核数与内存不是训练可行性保证，还需验证 GPU、存储和训练框架。"
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
            SCENE_DESC="商城应用和独立站的起步筛选档"
            AI_REASON="按页面、搜索、购物车和订单流程分别压测，核对数据库与缓存资源；日订单量不能直接推导实例规格。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        ecommerce-medium)
            SCENE_NAME="中型电商平台"
            SCENE_DESC="电商应用节点的扩展筛选档"
            AI_REASON="以下单链路的峰值请求和延迟目标验证配置；应用与数据库是否分离应结合瓶颈、恢复需求和成本判断。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=50 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=100 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=200 PRO_FAMILIES="S6 S5"
            ;;
        ecommerce-large)
            SCENE_NAME="大型电商/大促场景"
            SCENE_DESC="电商高峰活动和核心应用节点的较高资源筛选档"
            AI_REASON="峰值倍率和资源余量应由历史流量、活动计划与压测确定；还需评估限流、队列和扩容策略。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;

        #=====================================================================
        # 视频直播
        #=====================================================================
        video-transcode)
            SCENE_NAME="视频转码服务"
            SCENE_DESC="视频转码、格式转换和视频处理的候选筛选档"
            AI_REASON="转码速度与编码器、分辨率、帧率、预设和硬件加速有关；用代表性视频实测后确定并行任务数。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="C6 S5"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="C6 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="C6 S6"
            ;;
        live-streaming-small)
            SCENE_NAME="小型直播平台"
            SCENE_DESC="直播服务节点的起步筛选档"
            AI_REASON="根据码率、协议和分发方式测量网络与连接开销；是否使用 CDN 需结合分发需求和费用判断。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        live-streaming-medium)
            SCENE_NAME="中型直播平台"
            SCENE_DESC="直播服务节点的扩展筛选档"
            AI_REASON="用目标码率及连接模式验证 CPU、网络和源站负载；此档不对应固定观众数。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="S6 S5"
            ;;
        live-streaming-large)
            SCENE_NAME="大型直播平台"
            SCENE_DESC="直播源站或调度节点的较高资源筛选档"
            AI_REASON="先明确节点承担源站、转码还是调度职责，再评估分布式部署和 CDN 分发；观众容量需端到端测试。"
            ECO_CPU=8 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="S5 S6"
            BAL_CPU=16 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=1000 BAL_FAMILIES="S6 S5"
            PRO_CPU=32 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=2000 PRO_FAMILIES="S6 S5"
            ;;

        #=====================================================================
        # 游戏服务器
        #=====================================================================
        game-dev)
            SCENE_NAME="游戏开发测试服"
            SCENE_DESC="游戏服务端开发和联调的起步筛选档"
            AI_REASON="游戏引擎、地图和模拟负载可能有不同资源需求；按实际服务端进程的内存占用与 tick 耗时调整。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        game-small)
            SCENE_NAME="小型游戏服"
            SCENE_DESC="游戏服务节点的起步筛选档"
            AI_REASON="在线人数不能直接换算为核数；需按游戏逻辑、地图、tick 频率和玩家行为测试 CPU、内存及网络。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=50 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=100 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=200 PRO_FAMILIES="S6 S5"
            ;;
        game-medium)
            SCENE_NAME="中型游戏服"
            SCENE_DESC="游戏服务节点的扩展筛选档"
            AI_REASON="验证主线程耗时、CPU 单核性能和状态内存，再决定规格；此档不保证固定人数下的游戏延迟。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        game-large)
            SCENE_NAME="大型游戏服"
            SCENE_DESC="游戏服务节点的较高资源筛选档"
            AI_REASON="根据房间、分区或世界服架构测量单节点容量与跨节点开销；更大实例不自动等同于更多可承载玩家。"
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
            SCENE_DESC="物联网网关、边缘计算和协议转换的候选筛选档"
            AI_REASON="按协议、消息大小、上报频率和连接模式验证 CPU、内存与网络；设备数本身不足以确定容量。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=50 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        iot-platform-small)
            SCENE_NAME="小型物联网平台"
            SCENE_DESC="物联网接入与消息处理的起步筛选档"
            AI_REASON="分别测量长连接、消息处理和存储开销，并测试连接重建；此档不对应固定设备数。"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        iot-platform-medium)
            SCENE_NAME="中型物联网平台"
            SCENE_DESC="物联网接入与消息处理的扩展筛选档"
            AI_REASON="按消息速率、连接状态和队列积压测试节点容量；是否分片或集群部署应依据实际瓶颈判断。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 SA3"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S5 S6"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="S6 S5"
            ;;
        iot-platform-large)
            SCENE_NAME="大型物联网平台"
            SCENE_DESC="物联网接入或处理节点的较高资源筛选档"
            AI_REASON="需要结合接入、队列、处理及存储各层负载规划部署；本预设不定义单节点或集群设备容量。"
            ECO_CPU=8 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="S5 S6"
            BAL_CPU=16 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=1000 BAL_FAMILIES="S6 S5"
            PRO_CPU=32 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=2000 PRO_FAMILIES="S6 S5"
            ;;

        #=====================================================================
        # 大数据
        #=====================================================================
        bigdata-node)
            SCENE_NAME="大数据计算节点"
            SCENE_DESC="Spark、Flink 和 MapReduce 计算节点的候选筛选档"
            AI_REASON="以实际任务的并行度、状态大小、Shuffle、缓存和数据倾斜测试 CPU、内存及磁盘需求。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="M5 S5"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="M5 D3"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=50 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;
        bigdata-storage)
            SCENE_NAME="大数据存储节点"
            SCENE_DESC="HDFS DataNode 和 HBase RegionServer 的候选筛选档"
            AI_REASON="按数据量、复制因子、增长和读写模式核对磁盘容量与 IO；数据盘预设不代表本地盘或指定存储性能。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=500 ECO_FAMILIES="D3 S5"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=1000 BAL_FAMILIES="D3 M5"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=2000 PRO_FAMILIES="D3 M5"
            ;;
        bigdata-master)
            SCENE_NAME="大数据集群主节点"
            SCENE_DESC="YARN、HDFS 和 HBase 主节点的候选筛选档"
            AI_REASON="根据元数据量、集群规模及调度负载核对内存与 CPU，并单独规划高可用和恢复；此档不保证容量。"
            REC_PLATFORM="Ubuntu"
            ECO_CPU=2 ECO_MEM=4 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="SA2 S5"
            BAL_CPU=4 BAL_MEM=8 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 SA3"
            PRO_CPU=8 PRO_MEM=16 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        data-warehouse)
            SCENE_NAME="数据仓库"
            SCENE_DESC="ClickHouse、Doris 和 StarRocks 的候选筛选档"
            AI_REASON="用代表性查询测试数据扫描、聚合、并发和内存峰值；同时核对数据压缩、磁盘吞吐和增长需求。"
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
            SCENE_DESC="交易应用和订单撮合节点的候选筛选档"
            AI_REASON="核对端到端延迟目标，测试 CPU 调度、网络、持久化及外部依赖；实例规格不能保证微秒级响应。"
            ECO_CPU=4 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 S6"
            BAL_CPU=8 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S6 S5"
            PRO_CPU=16 PRO_MEM=32 PRO_DISK=100 PRO_DATA_DISK=500 PRO_FAMILIES="S6 S5"
            ;;
        fintech-risk)
            SCENE_NAME="风控系统"
            SCENE_DESC="实时风控、反欺诈和信用评估的候选筛选档"
            AI_REASON="用实际规则、特征查询和模型测量延迟及内存峰值；请求容量需结合数据依赖和目标服务等级验证。"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="M5 S5"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="M5 S6"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=500 PRO_FAMILIES="M6 M5"
            ;;
        fintech-settlement)
            SCENE_NAME="清算结算系统"
            SCENE_DESC="清算、账务处理和对账节点的候选筛选档"
            AI_REASON="以真实批次规模、完成时间窗口和数据库 IO 压测后定型，并单独规划一致性、恢复和高可用。"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 M5"
            ;;

        #=====================================================================
        # 数据库
        #=====================================================================
        database-small)
            SCENE_NAME="小型数据库"
            SCENE_DESC="MySQL、PostgreSQL 和 MongoDB 的起步筛选档"
            AI_REASON="按工作集、索引、连接数和读写模式测试内存与 IO；磁盘还需容纳日志、临时空间、备份和增长。"
            ECO_CPU=1 ECO_MEM=2 ECO_DISK=40 ECO_DATA_DISK=30 ECO_FAMILIES="SA2 SA3"
            BAL_CPU=2 BAL_MEM=4 BAL_DISK=40 BAL_DATA_DISK=50 BAL_FAMILIES="SA2 S5"
            PRO_CPU=4 PRO_MEM=8 PRO_DISK=50 PRO_DATA_DISK=100 PRO_FAMILIES="S5 S6"
            ;;
        database-medium)
            SCENE_NAME="中型数据库"
            SCENE_DESC="数据库节点的扩展筛选档"
            AI_REASON="缓存命中率取决于工作集与访问模式；用实际查询及事务测试内存、CPU 和磁盘，不以总数据量直接定型。"
            ECO_CPU=2 ECO_MEM=8 ECO_DISK=50 ECO_DATA_DISK=100 ECO_FAMILIES="S5 SA3"
            BAL_CPU=4 BAL_MEM=16 BAL_DISK=50 BAL_DATA_DISK=200 BAL_FAMILIES="S5 S6"
            PRO_CPU=8 PRO_MEM=32 PRO_DISK=50 PRO_DATA_DISK=500 PRO_FAMILIES="S6 M5"
            ;;
        database-large)
            SCENE_NAME="大型数据库"
            SCENE_DESC="数据库节点的较高资源筛选档"
            AI_REASON="按峰值事务、查询计划、工作集和恢复目标核对规格及磁盘性能；此档不保证高并发读写能力。"
            ECO_CPU=4 ECO_MEM=16 ECO_DISK=50 ECO_DATA_DISK=200 ECO_FAMILIES="S5 S6"
            BAL_CPU=8 BAL_MEM=32 BAL_DISK=50 BAL_DATA_DISK=500 BAL_FAMILIES="S6 M5"
            PRO_CPU=16 PRO_MEM=64 PRO_DISK=100 PRO_DATA_DISK=1000 PRO_FAMILIES="M6 M5"
            ;;

        #=====================================================================
        # 通用
        #=====================================================================
        dev)
            SCENE_NAME="开发测试环境"
            SCENE_DESC="开发、测试和学习环境的起步筛选档"
            AI_REASON="根据构建工具、容器数量及依赖服务核对实际 CPU、内存和磁盘需求；测试环境也可能需要较多资源。"
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
