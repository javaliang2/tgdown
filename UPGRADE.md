# 🔄 升级指南：从 v3.0 到 v3.1 Enhanced

## 平滑升级步骤

### 第 1 步：备份现有数据

```bash
# 备份数据库
cp tg_downloader.db tg_downloader.db.backup

# 备份配置
cp .env .env.backup
```

### 第 2 步：停止现有 Bot

```bash
# 如果使用本地运行
pkill -f "python.*bot.py"

# 如果使用 Docker
docker-compose down
```

### 第 3 步：获取最新代码

```bash
git pull origin main
```

### 第 4 步：安装新依赖

```bash
pip install -r requirements-enhanced.txt
```

### 第 5 步：启动新版本

```bash
# Docker
docker-compose up -d

# 或本地
python3 bot-enhanced.py
```

---

## 数据迁移

v3.1 完全兼容 v3.0 数据库，自动升级表结构。**无需手动干预！**

---

## 常见问题

### Q: 升级后旧数据丢失了吗？
**A:** 不会。V3.1 完全兼容 V3.0 数据库。

### Q: 如何回滚到 V3.0？
**A:** 
```bash
git checkout v3.0
cp tg_downloader.db.backup tg_downloader.db
python3 bot.py
```

---

**祝升级顺利！** 🎉