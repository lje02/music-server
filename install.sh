#!/bin/bash
# ============================================================
# Music Server 一键安装脚本
# 用法: bash install.sh [选项]
# 选项:
# --repo GitHub 仓库地址 (默认见下方 REPO 变量)
# --branch 分支名 (默认: main)
# --port Nginx 监听端口 (默认: 80)
# --no-nginx 跳过 Nginx 安装，仅运行 Flask/Gunicorn
# ============================================================

set -euo pipefail

# ────────────────────────── 配置区 ──────────────────────────
REPO="https://github.com/lje02/music-server.git" # ← 改成你的仓库地址
BRANCH="main"
INSTALL_DIR="/root/music-server"
SERVICE_NAME="music-player"
PORT=80
SKIP_NGINX=false
# ────────────────────────────────────────────────────────────

# ── 颜色输出 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 解析参数 ──
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --no-nginx) SKIP_NGINX=true; shift ;;
    *) error "未知参数: $1" ;;
  esac
done

# ── 检查 root ──
[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Music Server 一键安装 ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
info "仓库: $REPO"
info "分支: $BRANCH"
info "安装目录: $INSTALL_DIR"
info "端口: $PORT"
echo ""

# ── 1. 系统依赖 ──
info "安装系统依赖..."
apt-get update -qq
apt-get install -y -qq git python3 python3-pip python3-venv curl

if [[ "$SKIP_NGINX" == "false" ]]; then
  apt-get install -y -qq nginx
fi
success "系统依赖安装完成"

# ── 2. 拉取代码 ──
info "拉取代码..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  warn "目录已存在，执行 git pull 更新..."
  git -C "$INSTALL_DIR" pull origin "$BRANCH"
elif [[ -d "$INSTALL_DIR" ]]; then
  warn "目录 $INSTALL_DIR 已存在但不是 git 仓库，跳过拉取"
else
  git clone --depth=1 --branch "$BRANCH" "$REPO" "$INSTALL_DIR"
fi
success "代码已就绪: $INSTALL_DIR"

# ── 3. Python 虚拟环境 & 依赖 ──
info "创建 Python 虚拟环境..."
python3 -m venv "$INSTALL_DIR/.venv"
source "$INSTALL_DIR/.venv/bin/activate"

info "安装 Python 依赖..."
pip install --upgrade pip -q
pip install -r "$INSTALL_DIR/requirements.txt" -q
success "Python 环境就绪"

GUNICORN_BIN="$INSTALL_DIR/.venv/bin/gunicorn"

# ── 4. 创建 music 目录 ──
mkdir -p "$INSTALL_DIR/music"
info "音乐文件夹: $INSTALL_DIR/music (将你的音频文件放到这里)"

# ── 5. Systemd 服务 ──
info "配置 systemd 服务..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Music Player Web Server
After=network.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${GUNICORN_BIN} -w 2 -b 127.0.0.1:5000 app:app
Restart=always
RestartSec=5
Environment=PATH=${INSTALL_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"
success "systemd 服务已启动 (${SERVICE_NAME})"

# ── 6. Nginx ──
if [[ "$SKIP_NGINX" == "false" ]]; then
  info "配置 Nginx..."
  cat > "/etc/nginx/sites-available/${SERVICE_NAME}" <<EOF
server {
    listen ${PORT};
    server_name _;

    # 直接由 Nginx 托管音频文件，支持 Range 请求
    location /music/ {
        alias ${INSTALL_DIR}/music/;
        add_header Accept-Ranges bytes;
        add_header Cache-Control "public, max-age=3600";
    }

    # 静态前端
    location /static/ {
        alias ${INSTALL_DIR}/static/;
    }

    # API 和其余请求转发给 Flask
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  # 禁用默认站点，启用本站点
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "/etc/nginx/sites-available/${SERVICE_NAME}" \
         "/etc/nginx/sites-enabled/${SERVICE_NAME}"

  nginx -t && systemctl restart nginx
  success "Nginx 配置完成"
fi

# ── 7. 防火墙（可选，ufw 存在时自动开放端口）──
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
  ufw allow "$PORT"/tcp >/dev/null 2>&1 && info "ufw 已开放端口 $PORT"
fi

# ── 完成 ──
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} 安装完成！ ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

LOCAL_IP=$(hostname -I | awk '{print $1}')
if [[ "$SKIP_NGINX" == "false" ]]; then
  echo -e " 访问地址: ${CYAN}http://${LOCAL_IP}:${PORT}${NC}"
else
  echo -e " 访问地址: ${CYAN}http://${LOCAL_IP}:5000${NC} (直接访问 Flask)"
fi
echo ""
echo -e " 音乐目录: ${YELLOW}${INSTALL_DIR}/music/${NC}"
echo -e " 将 mp3/flac/wav 等音频文件放入该目录后刷新页面即可播放"
echo ""
echo -e " 常用命令:"
echo -e " systemctl status ${SERVICE_NAME} # 查看运行状态"
echo -e " systemctl restart ${SERVICE_NAME} # 重启服务"
echo -e " journalctl -u ${SERVICE_NAME} -f # 实时日志"
echo ""
