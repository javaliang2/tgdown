# 1️⃣ 克隆项目
git clone https://github.com/lje02/tgdown.git
cd tgdown

# 2️⃣ 运行一键部署脚本
bash install.sh

# 3️⃣ 脚本会引导你：
#    ✅ 检测环境（OS、Python、Docker）
#    ✅ 选择部署方式（Docker/Supervisor/Systemd/本地）
#    ✅ 生成 .env 配置文件
#    ✅ 安装依赖
#    ✅ 启动 Bot

查看状态：sudo systemctl status tg-downloader

查看日志：journalctl -u tg-downloader -f

停止服务：sudo systemctl stop tg-downloader

git安装

sudo apt install git-all

git更新

git clone git://git.kernel.org/pub/scm/git/git.git
## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lje02/tgdown/main/install.sh)
