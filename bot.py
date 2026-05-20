#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram 自动下载机器人 · Pyrogram 版
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ MTProto 协议 — 无文件大小限制
✅ 实时进度条（速度 / 剩余时间）
✅ 8 种媒体类型自动分类保存
✅ 内联按钮管理菜单（无需输入命令）
✅ 按日期子目录归档
✅ 用户白名单
✅ 并发下载
✅ 从 .env 读取配置
"""

import asyncio
import logging
import os
import time
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from pyrogram import Client, filters
from pyrogram.types import (
    Message,
    CallbackQuery,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
)

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

# 运行时可开关的类型白名单（True = 启用下载）
# 初始全部开启；通过菜单可逐类型切换
ENABLED_TYPES: dict[str, bool] = {k: True for k in MEDIA_DIRS}

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
    if h: return f"{h}h {m:02d}m"
    if m: return f"{m}m {s:02d}s"
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
    p = save_dir / name
    if p.exists():
        stem, suffix = Path(name).stem, Path(name).suffix
        p = save_dir / f"{stem}_{datetime.now().strftime('%H%M%S%f')}{suffix}"
    return p

def is_allowed(uid: int | None) -> bool:
    if uid is None:
        return True
    return not ALLOWED_USERS or uid in ALLOWED_USERS

def detect_media(msg: Message) -> tuple[str, str] | tuple[None, None]:
    mid = msg.id
    if msg.photo:        return "photo",      f"photo_{mid}.jpg"
    if msg.video:        return "video",       msg.video.file_name      or f"video_{mid}.mp4"
    if msg.audio:        return "audio",       msg.audio.file_name      or f"audio_{mid}.mp3"
    if msg.voice:        return "voice",       f"voice_{mid}.ogg"
    if msg.document:     return "document",    msg.document.file_name   or f"document_{mid}"
    if msg.sticker:
        s   = msg.sticker
        ext = ".webm" if s.is_video else (".tgs" if s.is_animated else ".webp")
        return "sticker", f"sticker_{mid}{ext}"
    if msg.animation:    return "animation",   msg.animation.file_name  or f"animation_{mid}.mp4"
    if msg.video_note:   return "video_note",  f"videonote_{mid}.mp4"
    return None, None

def get_file_size(msg: Message) -> int:
    for attr in ("photo","video","audio","voice","document","sticker","animation","video_note"):
        obj = getattr(msg, attr, None)
        if obj:
            return getattr(obj, "file_size", 0) or 0
    return 0

# ══════════════════════════════════════════════
#  统计数据
# ══════════════════════════════════════════════

def calc_stats() -> tuple[dict, int, int]:
    """返回 (per_type_dict, total_files, total_bytes)"""
    per = {}
    tf = ts = 0
    for mtype, base in MEDIA_DIRS.items():
        if not base.exists():
            per[mtype] = (0, 0)
            continue
        files = [f for f in base.rglob("*") if f.is_file()]
        cnt   = len(files)
        size  = sum(f.stat().st_size for f in files)
        per[mtype] = (cnt, size)
        tf += cnt
        ts += size
    return per, tf, ts

# ══════════════════════════════════════════════
#  键盘构建函数
# ══════════════════════════════════════════════

def kb_main() -> InlineKeyboardMarkup:
    """主菜单键盘"""
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("📊 下载统计", callback_data="menu:status"),
            InlineKeyboardButton("📁 目录结构", callback_data="menu:dirs"),
        ],
        [
            InlineKeyboardButton("🔧 类型开关", callback_data="menu:types"),
            InlineKeyboardButton("⚙️ 当前设置", callback_data="menu:settings"),
        ],
        [
            InlineKeyboardButton("🗑️ 清空统计", callback_data="menu:clear_confirm"),
            InlineKeyboardButton("🔄 刷新菜单", callback_data="menu:home"),
        ],
    ])

def kb_back() -> InlineKeyboardMarkup:
    """单个返回按钮"""
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("« 返回主菜单", callback_data="menu:home")]
    ])

def kb_types() -> InlineKeyboardMarkup:
    """类型开关键盘：每行两个，末行返回"""
    rows = []
    items = list(MEDIA_DIRS.keys())
    for i in range(0, len(items), 2):
        row = []
        for mtype in items[i:i+2]:
            flag  = "✅" if ENABLED_TYPES[mtype] else "❌"
            label = f"{flag} {media_emoji(mtype)} {mtype}"
            row.append(InlineKeyboardButton(label, callback_data=f"toggle:{mtype}"))
        rows.append(row)
    rows.append([InlineKeyboardButton("« 返回主菜单", callback_data="menu:home")])
    return InlineKeyboardMarkup(rows)

def kb_clear_confirm() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("⚠️ 确认清空", callback_data="menu:clear_do"),
            InlineKeyboardButton("✗ 取消",       callback_data="menu:home"),
        ]
    ])

# ══════════════════════════════════════════════
#  菜单文本构建
# ══════════════════════════════════════════════

def text_home(name: str) -> str:
    enabled  = sum(1 for v in ENABLED_TYPES.values() if v)
    _, tf, ts = calc_stats()
    return (
        f"👋 你好，**{name}**！\n\n"
        f"📥 **Telegram 自动下载机器人**\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🗂️ 已保存文件：**{tf}** 个  ({fmt_size(ts)})\n"
        f"🔛 启用类型：**{enabled}** / {len(MEDIA_DIRS)}\n"
        f"📂 根目录：`{DOWNLOAD_ROOT.resolve()}`\n\n"
        f"直接发送或转发媒体给我，自动保存 👇"
    )

def text_status() -> str:
    per, tf, ts = calc_stats()
    lines = ["📊 **下载统计**\n"]
    for mtype, (cnt, size) in per.items():
        flag = "✅" if ENABLED_TYPES[mtype] else "⏸"
        bar  = "▓" * min(cnt // max(1, tf // 10 + 1), 8) if tf else ""
        line = f"  {flag} {media_emoji(mtype)} **{mtype}**：{cnt} 个  {fmt_size(size)}  {bar}"
        lines.append(line)
    lines.append(f"\n📦 **合计**：{tf} 个文件，{fmt_size(ts)}")
    lines.append(f"\n🕐 更新时间：{datetime.now().strftime('%H:%M:%S')}")
    return "\n".join(lines)

def text_dirs() -> str:
    lines = [f"📁 **目录结构**\n`{DOWNLOAD_ROOT.resolve()}`\n"]
    for mtype, path in MEDIA_DIRS.items():
        exists = path.exists()
        mark   = "✅" if exists else "⬜"
        cnt    = len([f for f in path.rglob("*") if f.is_file()]) if exists else 0
        flag   = "▶" if ENABLED_TYPES[mtype] else "⏸"
        lines.append(
            f"  {mark}{flag} {media_emoji(mtype)} "
            f"`{path.relative_to(DOWNLOAD_ROOT)}`  _{cnt} 个_"
        )
    return "\n".join(lines)

def text_types() -> str:
    lines = ["🔧 **媒体类型开关**\n点击按钮切换启用 / 停用\n"]
    for mtype, enabled in ENABLED_TYPES.items():
        state = "✅ 启用" if enabled else "❌ 停用"
        lines.append(f"  {media_emoji(mtype)} {mtype}：{state}")
    return "\n".join(lines)

def text_settings() -> str:
    wl = "全部用户" if not ALLOWED_USERS else "、".join(str(u) for u in ALLOWED_USERS)
    enabled_list = [k for k, v in ENABLED_TYPES.items() if v]
    return (
        "⚙️ **当前运行设置**\n\n"
        f"📂 下载根目录\n`{DOWNLOAD_ROOT.resolve()}`\n\n"
        f"📅 按日期归档：{'✅ 开启' if ORGANIZE_BY_DATE else '❌ 关闭'}\n"
        f"⏱ 进度刷新间隔：{PROGRESS_UPDATE_SEC}s\n"
        f"👤 白名单：{wl}\n\n"
        f"🔛 启用的类型：\n"
        + "  " + "  ".join(media_emoji(t) for t in enabled_list)
    )

# ══════════════════════════════════════════════
#  进度回调工厂
# ══════════════════════════════════════════════

def make_progress(status_msg: Message, file_name: str,
                  media_type: str, total_hint: int = 0):
    last_t  = [0.0]
    start_t = [time.monotonic()]

    async def _cb(current: int, total: int):
        now = time.monotonic()
        if (now - last_t[0]) < PROGRESS_UPDATE_SEC and current < total:
            return
        last_t[0] = now

        total_real = total or total_hint or current
        pct        = current / total_real * 100 if total_real else 0
        elapsed    = max(now - start_t[0], 0.001)
        speed      = current / elapsed
        eta        = (total_real - current) / speed if speed > 0 and total_real > current else 0

        text = (
            f"{media_emoji(media_type)} **正在下载**\n"
            f"`{file_name}`\n\n"
            f"`{pbar(pct)}` **{pct:.1f}%**\n"
            f"📦 {fmt_size(current)} / {fmt_size(total_real)}\n"
            f"⚡ {fmt_speed(speed)}   ⏱ 剩余 {fmt_eta(eta)}"
        )
        try:
            await status_msg.edit_text(text)
        except Exception:
            pass

    return _cb

# ══════════════════════════════════════════════
#  命令处理器
# ══════════════════════════════════════════════

@bot.on_message(filters.command("start") & (filters.private | filters.group))
async def cmd_start(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    name = msg.from_user.first_name if msg.from_user else "用户"
    await msg.reply_text(
        text_home(name),
        reply_markup=kb_main(),
    )

# ── 保留文字命令作为快捷方式 ──────────────────

@bot.on_message(filters.command("menu") & (filters.private | filters.group))
async def cmd_menu(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    name = msg.from_user.first_name if msg.from_user else "用户"
    await msg.reply_text(text_home(name), reply_markup=kb_main())

@bot.on_message(filters.command("status") & (filters.private | filters.group))
async def cmd_status(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(text_status(), reply_markup=kb_back())

@bot.on_message(filters.command("dirs") & (filters.private | filters.group))
async def cmd_dirs(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(text_dirs(), reply_markup=kb_back())

# ══════════════════════════════════════════════
#  内联按钮回调处理
# ══════════════════════════════════════════════

@bot.on_callback_query()
async def on_callback(_, cq: CallbackQuery):
    uid = cq.from_user.id
    if not is_allowed(uid):
        await cq.answer("⛔ 无权限", show_alert=True)
        return

    data = cq.data
    name = cq.from_user.first_name or "用户"

    # ── 主菜单 ────────────────────────────────
    if data == "menu:home":
        await cq.message.edit_text(text_home(name), reply_markup=kb_main())
        await cq.answer()

    # ── 下载统计 ──────────────────────────────
    elif data == "menu:status":
        await cq.message.edit_text(text_status(), reply_markup=InlineKeyboardMarkup([
            [
                InlineKeyboardButton("🔄 刷新", callback_data="menu:status"),
                InlineKeyboardButton("« 返回", callback_data="menu:home"),
            ]
        ]))
        await cq.answer("已刷新")

    # ── 目录结构 ──────────────────────────────
    elif data == "menu:dirs":
        await cq.message.edit_text(text_dirs(), reply_markup=InlineKeyboardMarkup([
            [
                InlineKeyboardButton("🔄 刷新", callback_data="menu:dirs"),
                InlineKeyboardButton("« 返回", callback_data="menu:home"),
            ]
        ]))
        await cq.answer()

    # ── 类型开关面板 ──────────────────────────
    elif data == "menu:types":
        await cq.message.edit_text(text_types(), reply_markup=kb_types())
        await cq.answer()

    # ── 切换单个类型 ──────────────────────────
    elif data.startswith("toggle:"):
        mtype = data.split(":", 1)[1]
        if mtype in ENABLED_TYPES:
            ENABLED_TYPES[mtype] = not ENABLED_TYPES[mtype]
            state = "✅ 已启用" if ENABLED_TYPES[mtype] else "❌ 已停用"
            await cq.answer(f"{media_emoji(mtype)} {mtype} {state}", show_alert=False)
        # 刷新类型面板
        await cq.message.edit_text(text_types(), reply_markup=kb_types())

    # ── 当前设置 ──────────────────────────────
    elif data == "menu:settings":
        await cq.message.edit_text(text_settings(), reply_markup=kb_back())
        await cq.answer()

    # ── 清空确认 ──────────────────────────────
    elif data == "menu:clear_confirm":
        _, tf, ts = calc_stats()
        await cq.message.edit_text(
            f"🗑️ **确认清空统计？**\n\n"
            f"当前共 **{tf}** 个文件，{fmt_size(ts)}\n\n"
            f"⚠️ 此操作**只清空统计缓存**，不删除磁盘上的实际文件",
            reply_markup=kb_clear_confirm(),
        )
        await cq.answer()

    # ── 执行清空（重置统计，不删文件）────────
    elif data == "menu:clear_do":
        # "清空统计" 实际含义：重置 ENABLED_TYPES 到全部开启
        # 如果需要删除文件可在此扩展
        for k in ENABLED_TYPES:
            ENABLED_TYPES[k] = True
        await cq.message.edit_text(
            "✅ **已重置类型开关**\n所有媒体类型重新启用。\n磁盘文件未改动。",
            reply_markup=kb_back(),
        )
        await cq.answer("已重置", show_alert=True)

    else:
        await cq.answer("未知操作")

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

    # 类型开关检查
    if not ENABLED_TYPES.get(media_type, True):
        await msg.reply_text(
            f"{media_emoji(media_type)} **{media_type}** 类型已停用，跳过下载。\n"
            f"可在菜单 → 🔧 类型开关 中重新启用。",
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("🔧 打开类型开关", callback_data="menu:types")
            ]])
        )
        return

    safe_name = "".join(c if c not in r'\/:*?"<>|' else "_" for c in file_name)
    save_dir  = get_save_dir(media_type)
    save_path = safe_path(save_dir, safe_name)
    file_size = get_file_size(msg)
    em        = media_emoji(media_type)

    size_hint = f"  ({fmt_size(file_size)})" if file_size else ""
    status = await msg.reply_text(f"{em} 准备下载{size_hint}\n`{safe_name}` ...")

    progress_cb = make_progress(status, safe_name, media_type, file_size)

    t0 = time.monotonic()
    try:
        await msg.download(file_name=str(save_path), progress=progress_cb)
    except Exception as exc:
        logger.error(f"下载失败 [{media_type}] {safe_name}: {exc}")
        await status.edit_text(f"❌ **下载失败**\n`{exc}`")
        return

    elapsed  = time.monotonic() - t0
    act_size = save_path.stat().st_size if save_path.exists() else 0
    avg_spd  = act_size / elapsed if elapsed > 0 else 0

    logger.info(f"✅ [{media_type}] {save_path.name} ({fmt_size(act_size)}, {fmt_speed(avg_spd)}, {elapsed:.1f}s)")

    await status.edit_text(
        f"{em} **下载完成！**\n\n"
        f"📝 `{save_path.name}`\n"
        f"📦 {fmt_size(act_size)}\n"
        f"⚡ 均速 {fmt_speed(avg_spd)}\n"
        f"⏱ 耗时 {elapsed:.1f}s\n"
        f"💾 `{save_path}`",
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton("📊 查看统计", callback_data="menu:status"),
            InlineKeyboardButton("🏠 主菜单",   callback_data="menu:home"),
        ]])
    )

# ══════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════

if __name__ == "__main__":
    DOWNLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    logger.info(f"📁 下载目录：{DOWNLOAD_ROOT.resolve()}")
    logger.info(f"👤 白名单：{'全部用户' if not ALLOWED_USERS else ALLOWED_USERS}")
    logger.info("🤖 Bot 启动中（Pyrogram · MTProto · 内联菜单）…")
    bot.run()
