#!/usr/bin/env bash
# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

trap 'printf "${YELLOW}\nDownload interrupted. If you re-run the command, you can resume the download from the breakpoint.\n${NC}"; exit 1' INT

CONFIG_FILE="$HOME/.hfd_config"

# 初始化配置
init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf "${YELLOW}请输入 aria2c 的路径（例如：~/aria2c/aria2c），或者直接按回车使用系统安装的 aria2c：${NC}\n"
        read -p "Path to aria2c: " ARIA2C_PATH
        if [[ -z "$ARIA2C_PATH" ]]; then
            ARIA2C_PATH="aria2c"  # 使用系统默认的 aria2c
        fi
        echo "ARIA2C_PATH=$ARIA2C_PATH" > "$CONFIG_FILE"
    else
        source "$CONFIG_FILE"
    fi
}

display_help() {
    cat << EOF
Usage:
  hfd <repo_id> [--include include_pattern] [--exclude exclude_pattern] [--hf_username username] [--hf_token token] [--tool aria2c|wget] [-x threads] [--dataset] [--local-dir path]    

Description:
  Downloads a model or dataset from Hugging Face using the provided repo ID.

Parameters:
  repo_id        The Hugging Face repo ID in the format 'org/repo_name'.
  --include       (Optional) Flag to specify a string pattern to include files for downloading.
  --exclude       (Optional) Flag to specify a string pattern to exclude files from downloading.
  include/exclude_pattern The pattern to match against filenames, supports wildcard characters. e.g., '--exclude *.safetensor', '--include vae/*'.
  --hf_username   (Optional) Hugging Face username for authentication. **NOT EMAIL**.
  --hf_token      (Optional) Hugging Face token for authentication.
  --tool          (Optional) Download tool to use. Can be aria2c (default) or wget.
  -x              (Optional) Number of download threads for aria2c. Defaults to 4.
  --dataset       (Optional) Flag to indicate downloading a dataset.
  --local-dir     (Optional) Local directory path where the model or dataset will be stored.

Example:
  hfd bigscience/bloom-560m --exclude *.safetensors
  hfd meta-llama/Llama-2-7b --hf_username myuser --hf_token mytoken -x 4
  hfd lavita/medical-qa-shared-task-v1-toy --dataset
EOF
    exit 1
}

init_config  # 初始化配置
MODEL_ID=$1
shift

# Default values
TOOL="aria2c"
THREADS=4
HF_ENDPOINT=${HF_ENDPOINT:-"https://huggingface.co"}

while [[ $# -gt 0 ]]; do
    case $1 in
        --include) INCLUDE_PATTERN="$2"; shift 2 ;;
        --exclude) EXCLUDE_PATTERN="$2"; shift 2 ;;
        --hf_username) HF_USERNAME="$2"; shift 2 ;;
        --hf_token) HF_TOKEN="$2"; shift 2 ;;
        --tool) TOOL="$2"; shift 2 ;;
        -x) THREADS="$2"; shift 2 ;;
        --dataset) DATASET=1; shift ;;
        --local-dir) LOCAL_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Check if aria2, wget, curl, git, and git-lfs are installed
check_command() {
    if ! command -v $1 &>/dev/null; then
        echo -e "${RED}$1 未安装。请先安装它。${NC}"
        exit 1
    fi
}

# Mark current repo safe when using shared file system like samba or nfs
ensure_ownership() {
    if git status 2>&1 | grep "fatal: detected dubious ownership in repository at" > /dev/null; then
        git config --global --add safe.directory "${PWD}"
        printf "${YELLOW}检测到可疑的所有权，将 ${PWD} 标记为安全，若要恢复，请编辑 ~/.gitconfig。\n${NC}" 
    fi
}

[[ "$TOOL" == "aria2c" ]] && check_command "$ARIA2C_PATH"
[[ "$TOOL" == "wget" ]] && check_command wget
check_command curl; check_command git; check_command git-lfs

[[ -z "$MODEL_ID" || "$MODEL_ID" =~ ^-h ]] && display_help

if [[ -z "$LOCAL_DIR" ]]; then
    LOCAL_DIR="${MODEL_ID#*/}"
fi

if [[ "$DATASET" == 1 ]]; then
    MODEL_ID="datasets/$MODEL_ID"
fi
echo "Downloading to $LOCAL_DIR"

if [ -d "$LOCAL_DIR/.git" ]; then
    printf "${YELLOW}%s 已存在，跳过克隆。\n${NC}" "$LOCAL_DIR"
    cd "$LOCAL_DIR" && ensure_ownership && GIT_LFS_SKIP_SMUDGE=1 git pull || { printf "${RED}Git pull 失败。\n${NC}"; exit 1; }
else
    REPO_URL="$HF_ENDPOINT/$MODEL_ID"
    GIT_REFS_URL="${REPO_URL}/info/refs?service=git-upload-pack"
    echo "测试 GIT_REFS_URL: $GIT_REFS_URL"
    response=$(curl -s -o /dev/null -w "%{http_code}" "$GIT_REFS_URL")
    if [ "$response" == "401" ] || [ "$response" == "403" ]; then
        if [[ -z "$HF_USERNAME" || -z "$HF_TOKEN" ]]; then
            printf "${RED}HTTP 状态码: $response.\n该仓库需要身份验证，但未提供 --hf_username 和 --hf_token。请从 https://huggingface.co/settings/tokens 获取 token。\n退出。\n${NC}"
            exit 1
        fi
        REPO_URL="https://$HF_USERNAME:$HF_TOKEN@${HF_ENDPOINT#https://}/$MODEL_ID"
    elif [ "$response" != "200" ]; then
        printf "${RED}意外的 HTTP 状态码: $response\n${NC}"
        printf "${YELLOW}执行调试命令: curl -v %s\n输出:${NC}\n" "$GIT_REFS_URL"
        curl -v "$GIT_REFS_URL"; printf "\n${RED}Git 克隆失败。\n${NC}"; exit 1
    fi
    echo "GIT_LFS_SKIP_SMUDGE=1 git clone $REPO_URL $LOCAL_DIR"

    GIT_LFS_SKIP_SMUDGE=1 git clone $REPO_URL $LOCAL_DIR && cd "$LOCAL_DIR" || { printf "${RED}Git 克隆失败。\n${NC}"; exit 1; }

    ensure_ownership

    while IFS= read -r file; do
        truncate -s 0 "$file"
    done <<< $(git lfs ls-files | cut -d ' ' -f 3-)
fi

printf "\n开始下载 lfs 文件，bash 脚本:\ncd $LOCAL_DIR\n"
files=$(git lfs ls-files | cut -d ' ' -f 3-)
declare -a urls

while IFS= read -r file; do
    url="$HF_ENDPOINT/$MODEL_ID/resolve/main/$file"
    file_dir=$(dirname "$file")
    mkdir -p "$file_dir"
    if [[ "$TOOL" == "wget" ]]; then
        download_cmd="wget -c \"$url\" -O \"$file\""
        [[ -n "$HF_TOKEN" ]] && download_cmd="wget --header=\"Authorization: Bearer ${HF_TOKEN}\" -c \"$url\" -O \"$file\""
    else
        download_cmd="$ARIA2C_PATH --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c \"$url\" -d \"$file_dir\" -o \"$(basename "$file")\""
        [[ -n "$HF_TOKEN" ]] && download_cmd="$ARIA2C_PATH --header=\"Authorization: Bearer ${HF_TOKEN}\" --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c \"$url\" -d \"$file_dir\" -o \"$(basename "$file")\""
    fi
    [[ -n "$INCLUDE_PATTERN" && ! "$file" == $INCLUDE_PATTERN ]] && printf "# %s\n" "$download_cmd" && continue
    [[ -n "$EXCLUDE_PATTERN" && "$file" == $EXCLUDE_PATTERN ]] && printf "# %s\n" "$download_cmd" && continue
    printf "%s\n" "$download_cmd"
    urls+=("$url|$file")
done <<< "$files"

for url_file in "${urls[@]}"; do
    IFS='|' read -r url file <<< "$url_file"
    printf "${YELLOW}开始下载 ${file}。\n${NC}" 
    file_dir=$(dirname "$file")
    if [[ "$TOOL" == "wget" ]]; then
        [[ -n "$HF_TOKEN" ]] && wget --header="Authorization: Bearer ${HF_TOKEN}" -c "$url" -O "$file" || wget -c "$url" -O "$file"
    else
        [[ -n "$HF_TOKEN" ]] && $ARIA2C_PATH --header="Authorization: Bearer ${HF_TOKEN}" --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c "$url" -d "$file_dir" -o "$(basename "$file")" || $ARIA2C_PATH --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c "$url" -d "$file_dir" -o "$(basename "$file")"
    fi
    [[ $? -eq 0 ]] && printf "成功下载 %s。\n" "$url" || { printf "${RED}下载 %s 失败。\n${NC}" "$url"; exit 1; }
done

printf "${GREEN}下载成功完成。\n${NC}"
