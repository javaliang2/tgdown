#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Web 界面后端 API 服务（增强版）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
支持文件列表、搜索、在线播放等功能
与 bot-enhanced.py 共享数据库
"""

import os
import json
import sqlite3
import hashlib
from pathlib import Path
from datetime import datetime, timedelta
from functools import wraps

from flask import Flask, request, jsonify, send_from_directory, send_file
from flask_cors import CORS
from dotenv import load_dotenv
import jwt

# 导入流媒体模块
from web_streaming import register_streaming_routes

# ══════════════════════════════════════════════════════════════
#  初始化
# ═══════════════════════════════════════���══════════════════════
load_dotenv()

app = Flask(__name__, static_folder='web', static_url_path='')
CORS(app)

# 配置
SECRET_KEY = os.getenv("JWT_SECRET", "your-secret-key-change-me")
DB_PATH = Path(os.getenv("DB_PATH", "./tg_downloader.db"))
DOWNLOAD_ROOT = Path(os.getenv("DOWNLOAD_ROOT", "./downloads"))
ALLOWED_USERS_STR = os.getenv("ALLOWED_USERS", "")

# 允许的用户列表
ALLOWED_USERS = [
    int(x) for x in ALLOWED_USERS_STR.split(",") 
    if x.strip().isdigit()
]

# ══════════════════════════════════════════════════════════════
#  认证相关
# ══════════════════════════════════════════════════════════════

def generate_token(user_id: int) -> str:
    """生成 JWT Token"""
    payload = {
        'user_id': user_id,
        'exp': datetime.utcnow() + timedelta(days=7)
    }
    return jwt.encode(payload, SECRET_KEY, algorithm='HS256')

def verify_token(token: str) -> dict | None:
    """验证 JWT Token"""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=['HS256'])
        return payload
    except jwt.ExpiredSignatureError:
        return None
    except jwt.InvalidTokenError:
        return None

def token_required(f):
    """Token 验证装饰器"""
    @wraps(f)
    def decorated(*args, **kwargs):
        token = None
        
        # 从请求头获取 token
        if 'Authorization' in request.headers:
            auth_header = request.headers['Authorization']
            try:
                token = auth_header.split(" ")[1]
            except IndexError:
                return jsonify({'error': 'Invalid token format'}), 401
        
        # 从查询参数获取 token（兼容）
        if not token:
            token = request.args.get('token')
        
        if not token:
            return jsonify({'error': 'Token is missing'}), 401
        
        payload = verify_token(token)
        if not payload:
            return jsonify({'error': 'Invalid or expired token'}), 401
        
        request.user_id = payload['user_id']
        return f(*args, **kwargs)
    
    return decorated

# ══════════════════════════════════════════════════════════════
#  数据库操作
# ══════════════════════════════════════════════════════════════

def get_db():
    """获取数据库连接"""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn

def list_files_for_type(media_type: str, limit: int = 100) -> list:
    """获取指定类型的文件列表"""
    if not DB_PATH.exists():
        return []
    
    try:
        conn = get_db()
        rows = conn.execute(
            """SELECT id, file_name, file_size, downloaded_at, media_type, path 
               FROM files WHERE media_type = ?
               ORDER BY downloaded_at DESC LIMIT ?""",
            (media_type, limit)
        ).fetchall()
        conn.close()
        return [dict(row) for row in rows]
    except Exception as e:
        print(f"Database error: {e}")
        return []

def search_files(keyword: str, limit: int = 50) -> list:
    """搜索文件"""
    if not DB_PATH.exists():
        return []
    
    try:
        conn = get_db()
        rows = conn.execute(
            """SELECT id, file_name, file_size, downloaded_at, media_type, path 
               FROM files WHERE file_name LIKE ?
               ORDER BY downloaded_at DESC LIMIT ?""",
            (f"%{keyword}%", limit)
        ).fetchall()
        conn.close()
        return [dict(row) for row in rows]
    except Exception as e:
        print(f"Database error: {e}")
        return []

def get_all_stats() -> dict:
    """获取统计信息"""
    if not DB_PATH.exists():
        return {
            'total_files': 0,
            'total_size': 0,
            'by_type': {}
        }
    
    try:
        conn = get_db()
        # 总数和总大小
        row = conn.execute(
            "SELECT COUNT(*) as cnt, SUM(file_size) as total FROM files"
        ).fetchone()
        total_files = row['cnt'] or 0
        total_size = row['total'] or 0
        
        # 按类型统计
        rows = conn.execute(
            "SELECT media_type, COUNT(*) as cnt, SUM(file_size) as size FROM files GROUP BY media_type"
        ).fetchall()
        
        by_type = {}
        for row in rows:
            by_type[row['media_type']] = {
                'count': row['cnt'],
                'size': row['size']
            }
        
        conn.close()
        
        return {
            'total_files': total_files,
            'total_size': total_size,
            'by_type': by_type
        }
    except Exception as e:
        print(f"Database error: {e}")
        return {'total_files': 0, 'total_size': 0, 'by_type': {}}

# ══════════════════════════════════════════════════════════════
#  API 路由
# ══════════════════════════════════════════════════════════════

@app.route('/')
def index():
    """返回 Web 界面"""
    return send_from_directory(app.static_folder, 'index.html')

@app.route('/player')
def player():
    """播放器页面"""
    return send_from_directory(app.static_folder, 'player.html')

@app.route('/api/login', methods=['POST'])
def login():
    """
    登录接口
    POST /api/login
    {
        "password": "your-password"
    }
    """
    data = request.get_json()
    password = data.get('password', '')
    
    # 验证密码（使用环境变量中的密码）
    correct_password = os.getenv("WEB_PASSWORD", "admin")
    password_hash = os.getenv("WEB_PASSWORD_HASH", "")
    
    # 支持明文密码或哈希验证
    if password_hash:
        # 如果配置了哈希，使用哈希验证
        input_hash = hashlib.sha256(password.encode()).hexdigest()
        if input_hash != password_hash:
            return jsonify({'error': '密码错误'}), 401
    else:
        # 否则使用明文验证
        if password != correct_password:
            return jsonify({'error': '密码错误'}), 401
    
    # 生成 token（使用固定 user_id）
    token = generate_token(user_id=1)
    
    return jsonify({
        'success': True,
        'token': token,
        'message': '登录成功'
    })

@app.route('/api/files/<media_type>')
@token_required
def get_files(media_type):
    """
    获取指定类型的文件列表
    GET /api/files/{media_type}?token=YOUR_TOKEN&limit=50
    """
    limit = request.args.get('limit', 100, type=int)
    limit = min(limit, 500)  # 最多 500 个
    
    files = list_files_for_type(media_type, limit)
    
    return jsonify({
        'success': True,
        'media_type': media_type,
        'count': len(files),
        'files': files
    })

@app.route('/api/search')
@token_required
def search():
    """
    搜索文件
    GET /api/search?q=keyword&token=YOUR_TOKEN&limit=50
    """
    keyword = request.args.get('q', '').strip()
    if not keyword:
        return jsonify({'error': '搜索关键词不能为空'}), 400
    
    limit = request.args.get('limit', 50, type=int)
    limit = min(limit, 200)
    
    files = search_files(keyword, limit)
    
    return jsonify({
        'success': True,
        'keyword': keyword,
        'count': len(files),
        'files': files
    })

@app.route('/api/stats')
@token_required
def stats():
    """获取统计信息"""
    stats_data = get_all_stats()
    
    return jsonify({
        'success': True,
        'stats': stats_data,
        'update_time': datetime.now().isoformat()
    })

@app.route('/api/file/<int:file_id>/info')
@token_required
def get_file_info(file_id):
    """获取单个文件信息"""
    try:
        conn = get_db()
        row = conn.execute(
            "SELECT * FROM files WHERE id = ?",
            (file_id,)
        ).fetchone()
        conn.close()
        
        if not row:
            return jsonify({'error': '文件不存在'}), 404
        
        return jsonify({
            'success': True,
            'file': dict(row)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/download/<int:file_id>')
@token_required
def download_file(file_id):
    """下载文件"""
    try:
        conn = get_db()
        row = conn.execute(
            "SELECT * FROM files WHERE id = ?",
            (file_id,)
        ).fetchone()
        conn.close()
        
        if not row:
            return jsonify({'error': '文件不存在'}), 404
        
        file_path = Path(row['path'])
        
        if not file_path.exists():
            return jsonify({'error': '文件已删除'}), 404
        
        # 返回文件下载
        return send_file(
            file_path,
            as_attachment=True,
            download_name=row['file_name']
        )
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/play/<int:file_id>')
@token_required
def play_file(file_id):
    """
    获取播放器链接
    返回播放器页面的 URL
    """
    try:
        conn = get_db()
        row = conn.execute(
            "SELECT * FROM files WHERE id = ?",
            (file_id,)
        ).fetchone()
        conn.close()
        
        if not row:
            return jsonify({'error': '文件不存在'}), 404
        
        file_path = Path(row['path'])
        if not file_path.exists():
            return jsonify({'error': '文件已删除'}), 404
        
        # 生成播放器 URL
        token = request.args.get('token')
        player_url = f"/player?id={file_id}&token={token}"
        
        return jsonify({
            'success': True,
            'file_id': file_id,
            'file_name': row['file_name'],
            'media_type': row['media_type'],
            'player_url': player_url
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/health')
def health():
    """健康检查"""
    return jsonify({'status': 'ok'})

# ══════════════════════════════════════════════════════════════
#  错误处理
# ═════════════════════════════════════════════���════════════════

@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500

# ══════════════════════════════════════════════════════════════
#  注册流媒体路由
# ══════════════════════════════════════════════════════════════

register_streaming_routes(app, DB_PATH, DOWNLOAD_ROOT)

# ══════════════════════════════════════════════════════════════
#  启动
# ══════════════════════════════════════════════════════════════

if __name__ == '__main__':
    port = int(os.getenv("WEB_PORT", "5000"))
    debug = os.getenv("DEBUG", "false").lower() == "true"
    
    print(f"🌐 Web 服务启动：http://localhost:{port}")
    print(f"🔐 请使用 .env 中的 WEB_PASSWORD 登录")
    print(f"🎬 播放器：http://localhost:{port}/player?id=<file_id>&token=<token>")
    
    app.run(
        host='0.0.0.0',
        port=port,
        debug=debug,
        threaded=True
    )
