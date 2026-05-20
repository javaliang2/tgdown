#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram 自动下载机器人 · Pyrogram 版
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ MTProto 协议 — 无文件大小限制
✅ 实时进度条（速度 / 剩余时间）
✅ 8 种媒体类型自动分类保存
✅ 按日期子目录归档
✅ 用户白名单
✅ 并发下载（多条消息同时处理）
✅ 从 .env 读取配置，敏感信息不入代码
"""

import asyncio
import logging
import os
import time
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from pyrogram import Client, filters
from pyrogram.types import Message

# ══════════════════════════════════════════════
#  加载 .env
# ══════════════════════════════════════════════
load_dotenv()

def _require(key: str) -> str:
    v = os.getenv(key, "").strip()
    if not v or v.startswith("your_"):
        raise RuntimeError(f"❌ 请在 .env 中填写 {key}")
    return v

def _int_require(key: str) -> int:
    v = _require(key)
    try:
        return int(v)
    except ValueError:
        raise RuntimeError(f"❌ {key} 必须是整数，当前值：{v!r}")

API_ID    = _int_require("API_ID")
API_HASH  = _require("API_HASH")
BOT_TOKEN = _require("BOT_TOKEN")

DOWNLOAD_ROOT       = Path(os.getenv("DOWNLOAD_ROOT", "./downloads"))
ORGANIZE_BY_DATE    = os.getenv("ORGANIZE_BY_DATE", "true").lower() == "true"
PROGRESS_UPDATE_SEC = float(os.getenv("PROGRESS_UPDATE_SEC", "2.0"))
ALLOWED_USERS: list[int] = [
    int(x) for x in os.getenv("ALLOWED_USERS", "").split(",") if x.strip().isdigit()
]

# ══════════════════════════════════════════════
#  媒体目录映射
# ══════════════════════════════════════════════
MEDIA_DIRS: dict[str, Path] = {
    "photo"     : DOWNLOAD_ROOT / "photos",
    "video"     : DOWNLOAD_ROOT / "videos",
    "audio"     : DOWNLOAD_ROOT / "audios",
    "voice"     : DOWNLOAD_ROOT / "voices",
    "document"  : DOWNLOAD_ROOT / "documents",
    "sticker"   : DOWNLOAD_ROOT / "stickers",
    "animation" : DOWNLOAD_ROOT / "animations",
    "video_note": DOWNLOAD_ROOT / "video_notes",
}

# ══════════════════════════════════════════════
#  日志
# ══════════════════════════════════════════════
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# ══════════════════════════════════════════════
#  Pyrogram 客户端
# ══════════════════════════════════════════════
bot = Client(
    "tg_downloader_session",
    api_id=API_ID,
    api_hash=API_HASH,
    bot_token=BOT_TOKEN,
)

# ══════════════════════════════════════════════
#  工具函数
# ══════════════════════════════════════════════

def fmt_size(n: int) -> str:
    if n < 1024:     return f"{n} B"
    if n < 1 << 20:  return f"{n / 1024:.1f} KB"
    if n < 1 << 30:  return f"{n / (1 << 20):.1f} MB"
    return f"{n / (1 << 30):.2f} GB"


def fmt_speed(bps: float) -> str:
    if bps < 1024:    return f"{bps:.0f} B/s"
    if bps < 1 << 20: return f"{bps / 1024:.1f} KB/s"
    return f"{bps / (1 << 20):.1f} MB/s"


def fmt_eta(sec: float) -> str:
    sec = max(0, int(sec))
    h, rem = divmod(sec, 3600)
    m, s   = divmod(rem, 60)
    if h:   return f"{h}h {m:02d}m"
    if m:   return f"{m}m {s:02d}s"
    return f"{s}s"


def pbar(pct: float, width: int = 16) -> str:
    filled = int(width * pct / 100)
    return "█" * filled + "░" * (width - filled)


def media_emoji(t: str) -> str:
    return {
        "photo": "🖼️", "video": "🎬", "audio": "🎵",
        "voice": "🎤", "document": "📄", "sticker": "😄",
        "animation": "🎞️", "video_note": "📹",
    }.get(t, "📁")


def get_save_dir(media_type: str) -> Path:
    base = MEDIA_DIRS.get(media_type, DOWNLOAD_ROOT / "others")
    if ORGANIZE_BY_DATE:
        base = base / datetime.now().strftime("%Y-%m-%d")
    base.mkdir(parents=True, exist_ok=True)
    return base


def safe_path(save_dir: Path, name: str) -> Path:
    """文件名冲突时自动加微秒时间戳"""
    p = save_dir / name
    if p.exists():
        stem   = Path(name).stem
        suffix = Path(name).suffix
        p = save_dir / f"{stem}_{datetime.now().strftime('%H%M%S%f')}{suffix}"
    return p


def is_allowed(uid: int | None) -> bool:
    if uid is None:
        return True  # 频道消息无 from_user
    return not ALLOWED_USERS or uid in ALLOWED_USERS


def detect_media(msg: Message) -> tuple[str, str] | tuple[None, None]:
    mid = msg.id
    if msg.photo:
        return "photo", f"photo_{mid}.jpg"
    if msg.video:
        return "video", msg.video.file_name or f"video_{mid}.mp4"
    if msg.audio:
        return "audio", msg.audio.file_name or f"audio_{mid}.mp3"
    if msg.voice:
        return "voice", f"voice_{mid}.ogg"
    if msg.document:
        return "document", msg.document.file_name or f"document_{mid}"
    if msg.sticker:
        s   = msg.sticker
        ext = ".webm" if s.is_video else (".tgs" if s.is_animated else ".webp")
        return "sticker", f"sticker_{mid}{ext}"
    if msg.animation:
        return "animation", msg.animation.file_name or f"animation_{mid}.mp4"
    if msg.video_note:
        return "video_note", f"videonote_{mid}.mp4"
    return None, None


def get_file_size(msg: Message) -> int:
    """从消息对象里取文件大小（字节）"""
    for attr in ("photo", "video", "audio", "voice",
                 "document", "sticker", "animation", "video_note"):
        obj = getattr(msg, attr, None)
        if obj:
            return getattr(obj, "file_size", 0) or 0
    return 0


# ══════════════════════════════════════════════
#  进度回调工厂
# ══════════════════════════════════════════════

def make_progress(status_msg: Message, file_name: str,
                  media_type: str, total_hint: int = 0):
    """
    返回一个符合 Pyrogram progress= 签名的 async 回调。
    current / total 均由 Pyrogram 自动传入。
    """
    last_t     = [0.0]
    start_t    = [time.monotonic()]
    last_curr  = [0]

    async def _cb(current: int, total: int):
        now = time.monotonic()
        # 节流：未到刷新间隔且还没完成，直接跳过
        if (now - last_t[0]) < PROGRESS_UPDATE_SEC and current < total:
            return
        last_t[0]    = now
        last_curr[0] = current

        total_real = total or total_hint or current
        pct        = current / total_real * 100 if total_real else 0
        elapsed    = max(now - start_t[0], 0.001)
        speed      = current / elapsed
        eta        = (total_real - current) / speed if speed > 0 and total_real > current else 0

        em   = media_emoji(media_type)
        text = (
            f"{em} **正在下载**\n"
            f"`{file_name}`\n\n"
            f"`{pbar(pct)}` **{pct:.1f}%**\n"
            f"📦 {fmt_size(current)} / {fmt_size(total_real)}\n"
            f"⚡ {fmt_speed(speed)}   ⏱ 剩余 {fmt_eta(eta)}"
        )
        try:
            await status_msg.edit_text(text)
        except Exception:
            pass  # FloodWait / MessageNotModified 静默忽略

    return _cb


# ══════════════════════════════════════════════
#  命令处理器
# ══════════════════════════════════════════════

@bot.on_message(filters.command("start") & (filters.private | filters.group))
async def cmd_start(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(
        "👋 **Telegram 自动下载机器人**\n\n"
        "直接发送 / 转发给我：\n"
        "🖼️ 图片  🎬 视频  🎵 音频  🎤 语音\n"
        "📄 文档  😄 贴纸  🎞️ GIF  📹 视频留言\n\n"
        "文件将自动分类保存到服务器目录。\n\n"
        "📌 **命令**\n"
        "/start  — 帮助\n"
        "/status — 下载统计\n"
        "/dirs   — 目录结构\n\n"
        "🚀 Pyrogram · MTProto · **无大小限制**"
    )


@bot.on_message(filters.command("status") & (filters.private | filters.group))
async def cmd_status(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return

    lines = ["📊 **下载统计**\n"]
    total_files = total_size = 0
    for mtype, base in MEDIA_DIRS.items():
        if not base.exists():
            continue
        all_files = [f for f in base.rglob("*") if f.is_file()]
        if not all_files:
            continue
        cnt  = len(all_files)
        size = sum(f.stat().st_size for f in all_files)
        total_files += cnt
        total_size  += size
        lines.append(
            f"  {media_emoji(mtype)} **{mtype}**: {cnt} 个  ({fmt_size(size)})"
        )

    if total_files == 0:
        lines.append("  （暂无下载记录）")
    else:
        lines.append(f"\n📦 **合计**：{total_files} 个文件，{fmt_size(total_size)}")
    await msg.reply_text("\n".join(lines))


@bot.on_message(filters.command("dirs") & (filters.private | filters.group))
async def cmd_dirs(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return

    lines = [f"📁 **根目录**\n`{DOWNLOAD_ROOT.resolve()}`\n"]
    for mtype, path in MEDIA_DIRS.items():
        mark = "✅" if path.exists() else "⬜"
        # 统计文件数
        cnt = len([f for f in path.rglob("*") if f.is_file()]) if path.exists() else 0
        lines.append(f"  {mark} {media_emoji(mtype)} `{path.relative_to(DOWNLOAD_ROOT)}`  _{cnt} 个文件_")
    await msg.reply_text("\n".join(lines))


# ══════════════════════════════════════════════
#  核心：媒体消息处理
# ══════════════════════════════════════════════

MEDIA_FILTER = (
    filters.photo      |
    filters.video      |
    filters.audio      |
    filters.voice      |
    filters.document   |
    filters.sticker    |
    filters.animation  |
    filters.video_note
)


@bot.on_message(MEDIA_FILTER & (filters.private | filters.group))
async def handle_media(_client: Client, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return

    media_type, file_name = detect_media(msg)
    if media_type is None:
        return

    # 清理文件名中的非法字符
    safe_name = "".join(c if c not in r'\/:*?"<>|' else "_" for c in file_name)
    save_dir  = get_save_dir(media_type)
    save_path = safe_path(save_dir, safe_name)
    file_size = get_file_size(msg)
    em        = media_emoji(media_type)

    size_hint = f"  ({fmt_size(file_size)})" if file_size else ""
    status    = await msg.reply_text(
        f"{em} 准备下载{size_hint}\n`{safe_name}` ..."
    )

    progress_cb = make_progress(status, safe_name, media_type, file_size)

    t0 = time.monotonic()
    try:
        await msg.download(
            file_name=str(save_path),
            progress=progress_cb,
        )
    except Exception as exc:
        logger.error(f"下载失败 [{media_type}] {safe_name}: {exc}")
        await status.edit_text(f"❌ **下载失败**\n`{exc}`")
        return

    elapsed  = time.monotonic() - t0
    act_size = save_path.stat().st_size if save_path.exists() else 0
    avg_spd  = act_size / elapsed if elapsed > 0 else 0

    logger.info(
        f"✅ [{media_type}] {save_path.name} "
        f"({fmt_size(act_size)}, {fmt_speed(avg_spd)}, {elapsed:.1f}s)"
    )

    await status.edit_text(
        f"{em} **下载完成！**\n\n"
        f"📝 `{save_path.name}`\n"
        f"📦 {fmt_size(act_size)}\n"
        f"⚡ 均速 {fmt_speed(avg_spd)}\n"
        f"⏱ 耗时 {elapsed:.1f}s\n"
        f"💾 `{save_path}`"
    )


# ══════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════

if __name__ == "__main__":
    DOWNLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    logger.info(f"📁 下载目录：{DOWNLOAD_ROOT.resolve()}")
    logger.info(f"👤 白名单：{'全部用户' if not ALLOWED_USERS else ALLOWED_USERS}")
    logger.info("🤖 Bot 启动中（Pyrogram · MTProto）…")
    bot.run()
