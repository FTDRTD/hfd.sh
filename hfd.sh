#!/usr/bin/env bash
# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

trap 'printf "${YELLOW}\nDownload interrupted. If you re-run the command, you can resume the download from the breakpoint.\n${NC}"; exit 1' INT

display_help() {
    cat << EOF
用法：
  hfd <repo_id> [--include include_pattern1 include_pattern2 ...] [--exclude exclude_pattern1 exclude_pattern2 ...] [--hf_username username] [--hf_token token] [--tool aria2c|wget] [-x threads] [--dataset] [--local-dir path] [--aria2c-path path]
说明：
  从 Hugging Face 下载模型或数据集，使用提供的 repo ID。
参数：
  repo_id        Hugging Face 的 repo ID，格式为 'org/repo_name'。
  --include       （可选）指定要包含下载文件的字符串模式。支持多个模式。
  --exclude       （可选）指定要排除下载文件的字符串模式。支持多个模式。
  include/exclude_pattern 匹配文件名的模式，支持通配符字符。例如，'--exclude *.safetensor *.txt'，'--include vae/*'。
  --hf_username   （可选）用于身份验证的 Hugging Face 用户名。**不是邮箱**。
  --hf_token      （可选）用于身份验证的 Hugging Face 令牌。
  --tool          （可选）使用的下载工具。可以是 aria2c（默认）或 wget。
  -x              （可选）aria2c 的下载线程数。默认值为 4。
  --dataset       （可选）指示下载数据集的标志。
  --local-dir     （可选）存储模型或数据集的本地目录路径。
  --aria2c-path   （可选）aria2c 可执行文件的自定义路径。
示例：
  hfd bigscience/bloom-560m --exclude *.safetensors
  hfd meta-llama/Llama-2-7b --hf_username myuser --hf_token mytoken -x 4
  hfd lavita/medical-qa-shared-task-v1-toy --dataset
EOF
    exit 1
}

MODEL_ID=$1
shift

# Default values
TOOL="aria2c"
THREADS=4
HF_ENDPOINT=${HF_ENDPOINT:-"https://huggingface.co"}
ARIA2C_PATH=""

INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --include)
            shift
            while [[ $# -gt 0 && ! $1 =~ ^-- ]]; do
                INCLUDE_PATTERNS+=("$1")
                shift
            done
            ;;
        --exclude)
            shift
            while [[ $# -gt 0 && ! $1 =~ ^-- ]]; do
                EXCLUDE_PATTERNS+=("$1")
                shift
            done
            ;;
        --hf_username) HF_USERNAME="$2"; shift 2 ;;
        --hf_token) HF_TOKEN="$2"; shift 2 ;;
        --tool) TOOL="$2"; shift 2 ;;
        -x) THREADS="$2"; shift 2 ;;
        --dataset) DATASET=1; shift ;;
        --local-dir) LOCAL_DIR="$2"; shift 2 ;;
        --aria2c-path) ARIA2C_PATH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Check if aria2, wget, curl, git, and git-lfs are installed
check_command() {
    if ! command -v $1 &>/dev/null; then
        echo -e "${RED}$1 is not installed. Please install it first.${NC}"
        exit 1
    fi
}

# Mark current repo safe when using shared file system like samba or nfs
ensure_ownership() {
    if git status 2>&1 | grep "fatal: detected dubious ownership in repository at" > /dev/null; then
        git config --global --add safe.directory "${PWD}"
        printf "${YELLOW}Detected dubious ownership in repository, mark ${PWD} safe using git, edit ~/.gitconfig if you want to reverse this.\n${NC}" 
    fi
}

[[ "$TOOL" == "aria2c" ]] && check_command "${ARIA2C_PATH:-aria2c}"
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
    printf "${YELLOW}%s exists, Skip Clone.\n${NC}" "$LOCAL_DIR"
    cd "$LOCAL_DIR" && ensure_ownership && GIT_LFS_SKIP_SMUDGE=1 git pull || { printf "${RED}Git pull failed.${NC}\n"; exit 1; }
else
    REPO_URL="$HF_ENDPOINT/$MODEL_ID"
    GIT_REFS_URL="${REPO_URL}/info/refs?service=git-upload-pack"
    echo "Testing GIT_REFS_URL: $GIT_REFS_URL"
    response=$(curl -s -o /dev/null -w "%{http_code}" "$GIT_REFS_URL")
    if [ "$response" == "401" ] || [ "$response" == "403" ]; then
        if [[ -z "$HF_USERNAME" || -z "$HF_TOKEN" ]]; then
            printf "${RED}HTTP Status Code: $response.\nThe repository requires authentication, but --hf_username and --hf_token is not passed. Please get token from https://huggingface.co/settings/tokens.\nExiting.\n${NC}"
            exit 1
        fi
        REPO_URL="https://$HF_USERNAME:$HF_TOKEN@${HF_ENDPOINT#https://}/$MODEL_ID"
    elif [ "$response" != "200" ]; then
        printf "${RED}Unexpected HTTP Status Code: $response\n${NC}"
        printf "${YELLOW}Executing debug command: curl -v %s\nOutput:${NC}\n" "$GIT_REFS_URL"
        curl -v "$GIT_REFS_URL"; printf "\n${RED}Git clone failed.\n${NC}"; exit 1
    fi
    echo "GIT_LFS_SKIP_SMUDGE=1 git clone $REPO_URL $LOCAL_DIR"

    GIT_LFS_SKIP_SMUDGE=1 git clone $REPO_URL $LOCAL_DIR && cd "$LOCAL_DIR" || { printf "${RED}Git clone failed.\n${NC}"; exit 1; }

    ensure_ownership

    while IFS= read -r file; do
        truncate -s 0 "$file"
    done <<< $(git lfs ls-files | cut -d ' ' -f 3-)
fi

printf "\nStart Downloading lfs files, bash script:\ncd $LOCAL_DIR\n"
files=$(git lfs ls-files | cut -d ' ' -f 3-)
declare -a urls

file_matches_include_patterns() {
    local file="$1"
    for pattern in "${INCLUDE_PATTERNS[@]}"; do
        if [[ "$file" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

file_matches_exclude_patterns() {
    local file="$1"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$file" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

while IFS= read -r file; do
    url="$HF_ENDPOINT/$MODEL_ID/resolve/main/$file"
    file_dir=$(dirname "$file")
    mkdir -p "$file_dir"
    if [[ "$TOOL" == "wget" ]]; then
        download_cmd="wget -c \"$url\" -O \"$file\""
        [[ -n "$HF_TOKEN" ]] && download_cmd="wget --header=\"Authorization: Bearer ${HF_TOKEN}\" -c \"$url\" -O \"$file\""
    else
        ARIA2C_CMD="${ARIA2C_PATH:-aria2c}"
        download_cmd="$ARIA2C_CMD --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c \"$url\" -d \"$file_dir\" -o \"$(basename "$file")\""
        [[ -n "$HF_TOKEN" ]] && download_cmd="$ARIA2C_CMD --header=\"Authorization: Bearer ${HF_TOKEN}\" --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c \"$url\" -d \"$file_dir\" -o \"$(basename "$file")\""
    fi

    if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 ]]; then
        file_matches_include_patterns "$file" || { printf "# %s\n" "$download_cmd"; continue; }
    fi

    if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
        file_matches_exclude_patterns "$file" && { printf "# %s\n" "$download_cmd"; continue; }
    fi

    printf "%s\n" "$download_cmd"
    urls+=("$url|$file")
done <<< "$files"

for url_file in "${urls[@]}"; do
    IFS='|' read -r url file <<< "$url_file"
    printf "${YELLOW}Start downloading ${file}.\n${NC}" 
    file_dir=$(dirname "$file")
    if [[ "$TOOL" == "wget" ]]; then
        [[ -n "$HF_TOKEN" ]] && wget --header="Authorization: Bearer ${HF_TOKEN}" -c "$url" -O "$file" || wget -c "$url" -O "$file"
    else
        [[ -n "$HF_TOKEN" ]] && aria2c --header="Authorization: Bearer ${HF_TOKEN}" --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c "$url" -d "$file_dir" -o "$(basename "$file")" || aria2c --console-log-level=error --file-allocation=none -x $THREADS -s $THREADS -k 1M -c "$url" -d "$file_dir" -o "$(basename "$file")"
    fi
    [[ $? -eq 0 ]] && printf "Downloaded %s successfully.\n" "$url" || { printf "${RED}Failed to download %s.\n${NC}" "$url"; exit 1; }
done

printf "${GREEN}Download completed successfully.\n${NC}"
