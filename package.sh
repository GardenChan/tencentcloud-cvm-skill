#!/bin/bash
# 打包 Skill 为 zip 文件，用于上传到 ClawHub
set -euo pipefail

#=============================================================================
# Skill 元信息（修改这里）
#=============================================================================
SLUG="tencentcloud-cvm-skill"
DISPLAY_NAME="TencentCloud ServerOps"
VERSION="0.0.1"
TAGS="latest,tencent-cloud,cvm,devops,automation,cloud-server"

#=============================================================================
# 打包配置
#=============================================================================
# 要包含的文件和目录（相对于项目根目录）
INCLUDE_FILES=(
    "SKILL.md"
    "LICENSE"
    "scripts"
    "assets"
    "references"
)

# 要排除的模式
EXCLUDE_PATTERNS=(
    "*.DS_Store"
    "__pycache__"
    "*.pyc"
    ".git"
    ".gitignore"
    "node_modules"
    "*.log"
)

#=============================================================================
# 脚本逻辑
#=============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

打包 Skill 为 zip 文件，用于上传到 ClawHub

选项:
  --output <file>    指定输出文件名，默认 \${SLUG}-\${VERSION}.zip
  --list             仅列出将要打包的文件
  --info             显示 Skill 元信息
  -h, --help         显示帮助

示例:
  $(basename "$0")                    # 打包为 ${SLUG}-${VERSION}.zip
  $(basename "$0") --output my.zip    # 指定输出文件名
  $(basename "$0") --list             # 预览打包内容
EOF
}

show_info() {
    echo ""
    echo "========== Skill 元信息 =========="
    echo "Slug:         $SLUG"
    echo "Display Name: $DISPLAY_NAME"
    echo "Version:      $VERSION"
    echo "Tags:         $TAGS"
    echo "=================================="
    echo ""
}

list_files() {
    echo ""
    echo "========== 打包内容 =========="
    for item in "${INCLUDE_FILES[@]}"; do
        if [[ -e "$item" ]]; then
            if [[ -d "$item" ]]; then
                echo "[目录] $item/"
                find "$item" -type f | sed 's/^/  /'
            else
                echo "[文件] $item"
            fi
        else
            echo "[缺失] $item (警告: 文件不存在)"
        fi
    done
    echo "=================================="
    echo ""
}

# 参数解析
OUTPUT_FILE="${SLUG}.zip"
LIST_ONLY=false
INFO_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --list) LIST_ONLY=true; shift ;;
        --info) INFO_ONLY=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知选项: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$INFO_ONLY" == "true" ]]; then
    show_info
    exit 0
fi

if [[ "$LIST_ONLY" == "true" ]]; then
    show_info
    list_files
    exit 0
fi

# 显示信息
show_info

# 检查文件是否存在
info "检查文件..."
missing=()
for item in "${INCLUDE_FILES[@]}"; do
    if [[ ! -e "$item" ]]; then
        missing+=("$item")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    error "以下文件/目录不存在: ${missing[*]}"
    exit 1
fi
success "所有文件检查通过"

# 构建排除参数
EXCLUDE_ARGS=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    EXCLUDE_ARGS+=(-x "*/$pattern" -x "$pattern")
done

# 删除旧的 zip 文件
[[ -f "$OUTPUT_FILE" ]] && rm -f "$OUTPUT_FILE"

# 创建临时目录，以 SLUG 作为顶层文件夹名（不带版本号）
TEMP_DIR=$(mktemp -d)
TOP_FOLDER="${SLUG}"
TOP_DIR="$TEMP_DIR/$TOP_FOLDER"
mkdir -p "$TOP_DIR"

# 复制文件到临时目录
info "准备文件..."
for item in "${INCLUDE_FILES[@]}"; do
    if [[ -d "$item" ]]; then
        cp -R "$item" "$TOP_DIR/"
    else
        cp "$item" "$TOP_DIR/"
    fi
done

# 清理临时目录中的排除文件
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    find "$TOP_DIR" -name "$pattern" -exec rm -rf {} + 2>/dev/null || true
done

# 打包（从临时目录打包，确保只有一个顶层文件夹）
info "打包中..."
(cd "$TEMP_DIR" && zip -r "$SCRIPT_DIR/$OUTPUT_FILE" "$TOP_FOLDER" -q)

# 清理临时目录
rm -rf "$TEMP_DIR"

# 显示结果
FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
echo ""
success "打包完成!"
echo ""
echo "========== 输出信息 =========="
echo "文件名:   $OUTPUT_FILE"
echo "大小:     $FILE_SIZE"
echo "路径:     $SCRIPT_DIR/$OUTPUT_FILE"
echo ""
echo "上传到 ClawHub:"
echo "  Slug:         $SLUG"
echo "  Display Name: $DISPLAY_NAME"
echo "  Version:      $VERSION"
echo "  Tags:         $TAGS"
echo "=================================="
