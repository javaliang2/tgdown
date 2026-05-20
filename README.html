<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TG 自动下载机器人 · 使用指南</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Noto+Serif+SC:wght@400;600;700&family=JetBrains+Mono:wght@400;600&family=Space+Grotesk:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #0d0f14;
    --surface: #13161e;
    --surface2: #1a1e2a;
    --border: #252a38;
    --accent: #4f9eff;
    --accent2: #7c5cfc;
    --accent3: #2dd4b0;
    --warn: #f59e0b;
    --text: #e2e8f0;
    --text-dim: #8892a4;
    --text-muted: #4a5568;
    --code-bg: #0a0c11;
    --radius: 12px;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Space Grotesk', 'Noto Serif SC', sans-serif;
    line-height: 1.7;
    min-height: 100vh;
    overflow-x: hidden;
  }

  /* ── Background grid ── */
  body::before {
    content: '';
    position: fixed;
    inset: 0;
    background-image:
      linear-gradient(rgba(79,158,255,.03) 1px, transparent 1px),
      linear-gradient(90deg, rgba(79,158,255,.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
    z-index: 0;
  }

  .container {
    position: relative;
    z-index: 1;
    max-width: 860px;
    margin: 0 auto;
    padding: 60px 24px 120px;
  }

  /* ── Header ── */
  .header {
    text-align: center;
    margin-bottom: 72px;
  }

  .badge {
    display: inline-block;
    background: linear-gradient(135deg, var(--accent2) 0%, var(--accent) 100%);
    color: #fff;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: .12em;
    text-transform: uppercase;
    padding: 5px 16px;
    border-radius: 100px;
    margin-bottom: 24px;
  }

  h1 {
    font-family: 'Noto Serif SC', serif;
    font-size: clamp(2rem, 5vw, 3rem);
    font-weight: 700;
    background: linear-gradient(135deg, #fff 30%, var(--accent) 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
    line-height: 1.2;
    margin-bottom: 16px;
  }

  .subtitle {
    color: var(--text-dim);
    font-size: 1.05rem;
    max-width: 520px;
    margin: 0 auto;
  }

  /* ── Section ── */
  .section {
    margin-bottom: 48px;
  }

  .section-title {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: .75rem;
    font-weight: 600;
    letter-spacing: .15em;
    text-transform: uppercase;
    color: var(--accent);
    margin-bottom: 20px;
  }
  .section-title::after {
    content: '';
    flex: 1;
    height: 1px;
    background: var(--border);
  }

  /* ── Cards ── */
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 28px 32px;
    margin-bottom: 16px;
    position: relative;
    overflow: hidden;
    transition: border-color .2s;
  }
  .card:hover { border-color: #2e3650; }

  .card::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, var(--accent2), var(--accent));
    opacity: 0;
    transition: opacity .2s;
  }
  .card:hover::before { opacity: 1; }

  .card-head {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 10px;
  }

  .icon-box {
    width: 38px; height: 38px;
    border-radius: 10px;
    display: flex; align-items: center; justify-content: center;
    font-size: 18px;
    flex-shrink: 0;
  }
  .icon-box.blue   { background: rgba(79,158,255,.12); }
  .icon-box.purple { background: rgba(124,92,252,.12); }
  .icon-box.teal   { background: rgba(45,212,176,.12); }
  .icon-box.amber  { background: rgba(245,158,11,.12); }

  .card h3 {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text);
  }
  .card p {
    color: var(--text-dim);
    font-size: .92rem;
    line-height: 1.65;
  }

  /* ── Steps ── */
  .steps {
    counter-reset: step;
    display: flex;
    flex-direction: column;
    gap: 0;
  }

  .step {
    display: grid;
    grid-template-columns: 48px 1fr;
    gap: 0 20px;
    position: relative;
  }

  .step-num {
    counter-increment: step;
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  .step-num .num {
    width: 36px; height: 36px;
    border-radius: 50%;
    background: var(--surface2);
    border: 1.5px solid var(--border);
    display: flex; align-items: center; justify-content: center;
    font-size: .8rem;
    font-weight: 700;
    color: var(--accent);
    flex-shrink: 0;
    z-index: 1;
    font-family: 'JetBrains Mono', monospace;
  }

  .step-num .line {
    flex: 1;
    width: 1.5px;
    background: var(--border);
    margin: 4px 0;
  }

  .step:last-child .step-num .line { display: none; }

  .step-body {
    padding-bottom: 32px;
    padding-top: 6px;
  }
  .step:last-child .step-body { padding-bottom: 0; }

  .step-body h4 {
    font-size: .95rem;
    font-weight: 600;
    margin-bottom: 8px;
    color: var(--text);
  }

  .step-body p {
    font-size: .88rem;
    color: var(--text-dim);
    margin-bottom: 12px;
  }

  /* ── Code blocks ── */
  pre {
    background: var(--code-bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px 20px;
    overflow-x: auto;
    font-family: 'JetBrains Mono', monospace;
    font-size: .82rem;
    line-height: 1.7;
    color: #a8b9cc;
    position: relative;
  }

  pre .comment { color: var(--text-muted); }
  pre .kw    { color: var(--accent2); }
  pre .str   { color: var(--accent3); }
  pre .var   { color: var(--accent); }
  pre .num   { color: var(--warn); }

  code {
    font-family: 'JetBrains Mono', monospace;
    font-size: .85em;
    background: var(--surface2);
    border: 1px solid var(--border);
    padding: 2px 7px;
    border-radius: 5px;
    color: var(--accent3);
  }

  /* ── File tree ── */
  .tree {
    background: var(--code-bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 18px 22px;
    font-family: 'JetBrains Mono', monospace;
    font-size: .83rem;
    line-height: 2;
    color: var(--text-dim);
  }
  .tree .dir  { color: var(--accent); }
  .tree .file { color: var(--text-dim); }
  .tree .note { color: var(--text-muted); font-style: italic; }

  /* ── Media types grid ── */
  .media-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 12px;
  }

  .media-item {
    background: var(--surface2);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px;
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: .88rem;
  }
  .media-item .em { font-size: 1.4rem; }
  .media-item div { color: var(--text-dim); }
  .media-item strong { color: var(--text); display: block; font-size: .82rem; }

  /* ── Commands table ── */
  .cmd-list { display: flex; flex-direction: column; gap: 8px; }
  .cmd-row {
    display: flex;
    align-items: baseline;
    gap: 16px;
    padding: 12px 16px;
    background: var(--surface2);
    border-radius: 8px;
    border: 1px solid var(--border);
  }
  .cmd-row code { font-size: .82rem; min-width: 100px; }
  .cmd-row span { font-size: .88rem; color: var(--text-dim); }

  /* ── Alert ── */
  .alert {
    background: rgba(245,158,11,.06);
    border: 1px solid rgba(245,158,11,.25);
    border-radius: 10px;
    padding: 16px 20px;
    display: flex;
    gap: 12px;
    font-size: .88rem;
    color: #d4a72c;
    line-height: 1.6;
  }
  .alert-icon { font-size: 1.1rem; flex-shrink: 0; margin-top: 2px; }

  /* ── Footer ── */
  .footer {
    text-align: center;
    margin-top: 80px;
    padding-top: 32px;
    border-top: 1px solid var(--border);
    color: var(--text-muted);
    font-size: .82rem;
  }

  @media (max-width: 600px) {
    .container { padding: 40px 16px 80px; }
    .card { padding: 20px; }
    .media-grid { grid-template-columns: 1fr 1fr; }
  }
</style>
</head>
<body>
<div class="container">

  <!-- Header -->
  <div class="header">
    <div class="badge">✦ Telegram Bot · Python 3</div>
    <h1>自动媒体下载<br>机器人</h1>
    <p class="subtitle">发送或转发任意媒体文件给 Bot，自动按类型分类保存到服务器目录</p>
  </div>

  <!-- Supported types -->
  <div class="section">
    <div class="section-title">支持的媒体类型</div>
    <div class="media-grid">
      <div class="media-item"><span class="em">🖼️</span><div><strong>图片</strong>photos/</div></div>
      <div class="media-item"><span class="em">🎬</span><div><strong>视频</strong>videos/</div></div>
      <div class="media-item"><span class="em">🎵</span><div><strong>音频</strong>audios/</div></div>
      <div class="media-item"><span class="em">🎤</span><div><strong>语音</strong>voices/</div></div>
      <div class="media-item"><span class="em">📄</span><div><strong>文档/文件</strong>documents/</div></div>
      <div class="media-item"><span class="em">😄</span><div><strong>贴纸</strong>stickers/</div></div>
      <div class="media-item"><span class="em">🎞️</span><div><strong>动图 GIF</strong>animations/</div></div>
      <div class="media-item"><span class="em">📹</span><div><strong>视频留言</strong>video_notes/</div></div>
    </div>
  </div>

  <!-- Setup steps -->
  <div class="section">
    <div class="section-title">部署步骤</div>
    <div class="steps">

      <div class="step">
        <div class="step-num"><div class="num">01</div><div class="line"></div></div>
        <div class="step-body">
          <h4>创建 Telegram Bot，获取 Token</h4>
          <p>在 Telegram 中找到 <strong>@BotFather</strong>，发送 <code>/newbot</code>，按提示设置名称，复制返回的 Token。</p>
        </div>
      </div>

      <div class="step">
        <div class="step-num"><div class="num">02</div><div class="line"></div></div>
        <div class="step-body">
          <h4>克隆代码 &amp; 安装依赖</h4>
          <pre><span class="comment"># 创建并进入项目目录</span>
mkdir tg-downloader-bot &amp;&amp; cd tg-downloader-bot

<span class="comment"># 创建虚拟环境（推荐）</span>
python3 -m venv venv
source venv/bin/activate      <span class="comment"># Windows: venv\Scripts\activate</span>

<span class="comment"># 安装依赖</span>
pip install -r requirements.txt</pre>
        </div>
      </div>

      <div class="step">
        <div class="step-num"><div class="num">03</div><div class="line"></div></div>
        <div class="step-body">
          <h4>填写 Token，按需调整配置</h4>
          <p>编辑 <code>bot.py</code> 顶部的配置区域：</p>
          <pre><span class="var">BOT_TOKEN</span>       = <span class="str">"123456:ABC-xxx"</span>   <span class="comment"># ← 粘贴你的 Token</span>
<span class="var">DOWNLOAD_ROOT</span>   = Path(<span class="str">"./downloads"</span>)  <span class="comment"># 下载根目录</span>
<span class="var">MAX_FILE_SIZE_MB</span>= <span class="num">0</span>                 <span class="comment"># 0=不限制</span>
<span class="var">ORGANIZE_BY_DATE</span>= <span class="kw">True</span>              <span class="comment"># 按日期子目录</span></pre>
        </div>
      </div>

      <div class="step">
        <div class="step-num"><div class="num">04</div><div class="line"></div></div>
        <div class="step-body">
          <h4>启动机器人</h4>
          <pre><span class="comment"># 直接运行（前台）</span>
python bot.py

<span class="comment"># 后台运行（nohup）</span>
nohup python bot.py &gt; bot.log 2&gt;&amp;1 &amp;

<span class="comment"># 或注册为 systemd 服务（推荐生产环境）</span>
sudo cp tg-downloader.service /etc/systemd/system/
sudo systemctl enable --now tg-downloader</pre>
        </div>
      </div>

      <div class="step">
        <div class="step-num"><div class="num">05</div><div class="line"></div></div>
        <div class="step-body">
          <h4>发送媒体，开始自动下载 🎉</h4>
          <p>打开 Telegram，找到你的 Bot，直接发送或转发任意图片/视频/文件，Bot 会立即回复保存路径。</p>
        </div>
      </div>

    </div>
  </div>

  <!-- File structure -->
  <div class="section">
    <div class="section-title">目录结构</div>
    <div class="tree">
<span class="dir">downloads/</span>
├── <span class="dir">photos/</span>
│   └── <span class="dir">2024-06-15/</span>  <span class="note">← ORGANIZE_BY_DATE=True 时按日期分组</span>
│       ├── <span class="file">photo_123.jpg</span>
│       └── <span class="file">photo_124.jpg</span>
├── <span class="dir">videos/</span>
│   └── <span class="dir">2024-06-15/</span>
├── <span class="dir">audios/</span>
├── <span class="dir">voices/</span>
├── <span class="dir">documents/</span>
├── <span class="dir">stickers/</span>
├── <span class="dir">animations/</span>
└── <span class="dir">video_notes/</span>
    </div>
  </div>

  <!-- Commands -->
  <div class="section">
    <div class="section-title">Bot 命令</div>
    <div class="cmd-list">
      <div class="cmd-row"><code>/start</code><span>显示帮助信息</span></div>
      <div class="cmd-row"><code>/status</code><span>查看各类型下载数量和总大小统计</span></div>
      <div class="cmd-row"><code>/dirs</code><span>查看服务器上各保存目录路径</span></div>
    </div>
  </div>

  <!-- Notes -->
  <div class="section">
    <div class="section-title">注意事项</div>
    <div class="alert">
      <span class="alert-icon">⚠️</span>
      <div>
        Telegram Bot API 对单文件下载有 <strong>20 MB</strong> 的限制（通过 getFile 接口）。超过 20 MB 的文件需要使用
        <strong>MTProto 客户端</strong>（如 Pyrogram / Telethon）才能完整下载。如有大文件需求，可在 <code>bot.py</code> 中将
        <code>MAX_FILE_SIZE_MB</code> 设为 20，并配合 Pyrogram 版本使用。
      </div>
    </div>
  </div>

  <!-- Tech stack -->
  <div class="section">
    <div class="section-title">技术栈</div>
    <div style="display:flex;flex-wrap:wrap;gap:10px;">
      <div class="card" style="flex:1;min-width:180px;padding:18px 20px;">
        <div class="card-head"><div class="icon-box blue">🐍</div><h3>Python 3.9+</h3></div>
        <p>异步 asyncio 驱动，高效处理并发下载</p>
      </div>
      <div class="card" style="flex:1;min-width:180px;padding:18px 20px;">
        <div class="card-head"><div class="icon-box purple">📦</div><h3>python-telegram-bot 21</h3></div>
        <p>官方推荐库，原生支持 async/await</p>
      </div>
      <div class="card" style="flex:1;min-width:180px;padding:18px 20px;">
        <div class="card-head"><div class="icon-box teal">🗂️</div><h3>pathlib</h3></div>
        <p>跨平台路径管理，自动创建目录结构</p>
      </div>
    </div>
  </div>

  <div class="footer">
    tg-downloader-bot · Python · MIT License
  </div>

</div>
</body>
</html>
