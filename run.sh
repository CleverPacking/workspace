#!/bin/bash
set -e

PROJECT_DIR="/var/www/bsmp"
echo "Creating project at $PROJECT_DIR..."

mkdir -p "$PROJECT_DIR"/{routes,views,public,data}
cd "$PROJECT_DIR"

# ---- .env ----
cat > .env << 'EOF'
PORT=3004
BAGEL_API_KEY=your_actual_api_key_here
BAGEL_API_BASE=https://api.bagelsmp.com/v1
ITEM_API_BASE=https://api.minecraftitems.xyz/api/item
UPDATE_INTERVAL=30000
EOF

# ---- package.json ----
cat > package.json << 'EOF'
{
  "name": "bagel-dashboard",
  "version": "1.0.0",
  "description": "Live dashboard for Bagel SMP",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js"
  },
  "dependencies": {
    "axios": "^1.6.0",
    "better-sqlite3": "^9.0.0",
    "dotenv": "^16.3.1",
    "ejs": "^3.1.9",
    "express": "^4.18.2",
    "express-session": "^1.17.3"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  }
}
EOF

# ---- db.js ----
cat > db.js << 'EOF'
const Database = require('better-sqlite3');
const path = require('path');

const db = new Database(path.join(__dirname, 'data', 'bagel.db'));
db.pragma('journal_mode = WAL');

db.exec(`
  CREATE TABLE IF NOT EXISTS server_status (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    online INTEGER,
    players INTEGER,
    motd TEXT,
    updated_at INTEGER
  );
  INSERT OR IGNORE INTO server_status (id, online, players, motd, updated_at) 
  VALUES (1, 0, 0, '', 0);

  CREATE TABLE IF NOT EXISTS prices (
    item_name TEXT PRIMARY KEY,
    price_usd REAL,
    change_percent REAL,
    updated_at INTEGER
  );

  CREATE TABLE IF NOT EXISTS auctions (
    auction_id TEXT PRIMARY KEY,
    item_name TEXT,
    starting_bid INTEGER,
    buy_now INTEGER,
    seller TEXT,
    updated_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_auctions_item ON auctions(item_name);
  CREATE INDEX IF NOT EXISTS idx_auctions_buynow ON auctions(buy_now);

  CREATE TABLE IF NOT EXISTS bounties (
    target TEXT PRIMARY KEY,
    amount INTEGER,
    placed_by TEXT,
    updated_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_bounties_amount ON bounties(amount);

  CREATE TABLE IF NOT EXISTS orders (
    order_id TEXT PRIMARY KEY,
    item_name TEXT,
    quantity INTEGER,
    unit_price INTEGER,
    buyer TEXT,
    updated_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_orders_item ON orders(item_name);

  CREATE TABLE IF NOT EXISTS leaderboards (
    category TEXT,
    rank INTEGER,
    uuid TEXT,
    name TEXT,
    rank_id TEXT,
    type TEXT,
    value INTEGER,
    updated_at INTEGER,
    PRIMARY KEY (category, rank)
  );
  CREATE INDEX IF NOT EXISTS idx_leaderboards_category ON leaderboards(category);

  CREATE TABLE IF NOT EXISTS player_searches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    player_name TEXT,
    searched_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_player_searches_name ON player_searches(player_name);
  CREATE INDEX IF NOT EXISTS idx_player_searches_time ON player_searches(searched_at);

  CREATE TABLE IF NOT EXISTS item_stats (
    item_name TEXT PRIMARY KEY,
    search_count INTEGER DEFAULT 0,
    last_searched INTEGER
  );
`);

function getServerStatus() {
  return db.prepare('SELECT * FROM server_status WHERE id = 1').get() || { online: 0, players: 0, motd: '', updated_at: 0 };
}
function updateServerStatus({ online, players, motd }) {
  db.prepare('UPDATE server_status SET online = ?, players = ?, motd = ?, updated_at = ? WHERE id = 1')
    .run(online ? 1 : 0, players, motd, Math.floor(Date.now() / 1000));
}
function upsertPrices(prices) {
  const stmt = db.prepare('INSERT OR REPLACE INTO prices (item_name, price_usd, change_percent, updated_at) VALUES (?, ?, ?, ?)');
  const now = Math.floor(Date.now() / 1000);
  db.transaction((items) => { for (const i of items) stmt.run(i.item_name, i.price_usd, i.change_percent || 0, now); })(prices);
}
function getPrices() { return db.prepare('SELECT * FROM prices ORDER BY item_name').all(); }
function upsertAuctions(auctions) {
  const stmt = db.prepare('INSERT OR REPLACE INTO auctions (auction_id, item_name, starting_bid, buy_now, seller, updated_at) VALUES (?, ?, ?, ?, ?, ?)');
  const now = Math.floor(Date.now() / 1000);
  db.transaction((items) => { for (const a of items) stmt.run(a.auction_id, a.item_name, a.starting_bid, a.buy_now, a.seller, now); })(auctions);
}
function getAuctions() { return db.prepare('SELECT * FROM auctions ORDER BY updated_at DESC').all(); }
function getAuctionsByItem(itemName) { return db.prepare('SELECT * FROM auctions WHERE item_name LIKE ? ORDER BY buy_now ASC').all(`%${itemName}%`); }
function getBestDeals(limit = 5) { return db.prepare('SELECT * FROM auctions WHERE buy_now IS NOT NULL ORDER BY buy_now ASC LIMIT ?').all(limit); }
function upsertBounties(bounties) {
  const stmt = db.prepare('INSERT OR REPLACE INTO bounties (target, amount, placed_by, updated_at) VALUES (?, ?, ?, ?)');
  const now = Math.floor(Date.now() / 1000);
  db.transaction((items) => { for (const b of items) stmt.run(b.target, b.amount, b.placed_by, now); })(bounties);
}
function getBounties(sort = 'name_asc') {
  const order = sort === 'price_desc' ? 'amount DESC' : sort === 'price_asc' ? 'amount ASC' : 'target ASC';
  return db.prepare(`SELECT * FROM bounties ORDER BY ${order}`).all();
}
function upsertOrders(orders) {
  const stmt = db.prepare('INSERT OR REPLACE INTO orders (order_id, item_name, quantity, unit_price, buyer, updated_at) VALUES (?, ?, ?, ?, ?, ?)');
  const now = Math.floor(Date.now() / 1000);
  db.transaction((items) => { for (const o of items) stmt.run(o.order_id, o.item_name, o.quantity, o.unit_price, o.buyer, now); })(orders);
}
function getOrders() { return db.prepare('SELECT * FROM orders ORDER BY updated_at DESC').all(); }
function upsertLeaderboard(category, entries) {
  db.prepare('DELETE FROM leaderboards WHERE category = ?').run(category);
  const stmt = db.prepare('INSERT INTO leaderboards (category, rank, uuid, name, rank_id, type, value, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
  const now = Math.floor(Date.now() / 1000);
  db.transaction((items) => { for (const e of items) stmt.run(category, e.rank, e.uuid, e.name, e.rank_id, e.type, e.value, now); })(entries);
}
function getLeaderboard(category, limit = 10) { return db.prepare('SELECT * FROM leaderboards WHERE category = ? ORDER BY rank LIMIT ?').all(category, limit); }
function getLeaderboardCategories() { return db.prepare('SELECT DISTINCT category FROM leaderboards').all().map(r => r.category); }
function recordPlayerSearch(name) { db.prepare('INSERT INTO player_searches (player_name, searched_at) VALUES (?, ?)').run(name, Math.floor(Date.now() / 1000)); }
function getTopSearchedPlayers(limit = 5) {
  return db.prepare('SELECT player_name, COUNT(*) as count FROM player_searches WHERE searched_at > strftime("%s", "now", "-1 day") GROUP BY player_name ORDER BY count DESC LIMIT ?').all(limit);
}
function recordItemSearch(name) {
  db.prepare('INSERT INTO item_stats (item_name, search_count, last_searched) VALUES (?, 1, ?) ON CONFLICT(item_name) DO UPDATE SET search_count = search_count + 1, last_searched = excluded.last_searched')
    .run(name, Math.floor(Date.now() / 1000));
}
function getTopItems(limit = 5) { return db.prepare('SELECT item_name, search_count FROM item_stats ORDER BY search_count DESC LIMIT ?').all(limit); }
function getTopWantedItems(limit = 5) { return getTopItems(limit); }

module.exports = {
  db, getServerStatus, updateServerStatus, upsertPrices, getPrices,
  upsertAuctions, getAuctions, getAuctionsByItem, getBestDeals,
  upsertBounties, getBounties, upsertOrders, getOrders,
  upsertLeaderboard, getLeaderboard, getLeaderboardCategories,
  recordPlayerSearch, getTopSearchedPlayers, recordItemSearch, getTopItems, getTopWantedItems
};
EOF

# ---- api.js ----
cat > api.js << 'EOF'
const axios = require('axios');
require('dotenv').config();
const BASE = process.env.BAGEL_API_BASE;
const API_KEY = process.env.BAGEL_API_KEY;
const client = axios.create({ baseURL: BASE, headers: { 'Authorization': `Bearer ${API_KEY}`, 'Content-Type': 'application/json' }, timeout: 10000 });
async function get(endpoint, params = {}) {
  try {
    const res = await client.get(endpoint, { params });
    return res.data;
  } catch (err) {
    throw new Error(err.response?.data?.message || `API Error ${err.response?.status}`);
  }
}
module.exports = {
  getStatus: () => get('/status'),
  getPlayer: (name) => get(`/players/${encodeURIComponent(name)}`),
  getPrices: () => get('/prices'),
  getAuctions: () => get('/auctions'),
  getLeaderboard: (category, limit = 100) => get(`/leaderboards/${category}`, { limit }),
  getBounties: () => get('/bounties'),
  getOrders: () => get('/orders'),
  getTeam: (name) => get(`/teams/${encodeURIComponent(name)}`),
};
EOF

# ---- updater.js ----
cat > updater.js << 'EOF'
const api = require('./api');
const db = require('./db');
const CATEGORIES = ['money', 'kills', 'playtime', 'mobs_killed', 'blocks_broken', 'blocks_placed', 'deaths', 'shards'];

async function updateAll() {
  console.log('[Updater] Fetching data...');
  try {
    const status = await api.getStatus();
    db.updateServerStatus({ online: status.online || false, players: status.players || 0, motd: status.motd || '' });

    const prices = await api.getPrices();
    if (prices && Array.isArray(prices)) db.upsertPrices(prices);

    const auctions = await api.getAuctions();
    if (auctions?.listings) db.upsertAuctions(auctions.listings);

    const bounties = await api.getBounties();
    if (bounties?.bounties) db.upsertBounties(bounties.bounties);

    const orders = await api.getOrders();
    if (orders?.orders) db.upsertOrders(orders.orders);

    for (const cat of CATEGORIES) {
      try {
        const data = await api.getLeaderboard(cat, 100);
        if (data?.entries) db.upsertLeaderboard(cat, data.entries);
      } catch (e) { console.error(`[Updater] Failed ${cat}:`, e.message); }
    }
    console.log('[Updater] Done.');
  } catch (err) { console.error('[Updater] Error:', err.message); }
}

function startUpdater(intervalMs = 30000) {
  updateAll();
  setInterval(updateAll, intervalMs);
  console.log(`[Updater] Started, interval ${intervalMs}ms`);
}
module.exports = { startUpdater, updateAll };
EOF

# ---- server.js ----
cat > server.js << 'EOF'
require('dotenv').config();
const express = require('express');
const session = require('express-session');
const path = require('path');
const { startUpdater } = require('./updater');
const app = express();
const PORT = process.env.PORT || 3004;

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.static('public'));
app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.use(session({ secret: 'bagel-dashboard-secret', resave: false, saveUninitialized: true, cookie: { maxAge: 24*60*60*1000 } }));

const db = require('./db');
app.use((req, res, next) => {
  const status = db.getServerStatus();
  res.locals.serverStatus = { online: status.online === 1, players: status.players, motd: status.motd, updated_at: status.updated_at };
  res.locals.itemIconBase = process.env.ITEM_API_BASE || 'https://api.minecraftitems.xyz/api/item';
  next();
});

app.use('/', require('./routes/index'));
app.use('/players', require('./routes/players'));
app.use('/prices', require('./routes/prices'));
app.use('/auctions', require('./routes/auctions'));
app.use('/leaderboards', require('./routes/leaderboards'));
app.use('/bounties', require('./routes/bounties'));
app.use('/orders', require('./routes/orders'));
app.use('/teams', require('./routes/teams'));

app.use((req, res) => res.status(404).render('404', { title: 'Not Found' }));

app.listen(PORT, () => {
  console.log(`✅ Server running on http://localhost:${PORT}`);
  startUpdater(parseInt(process.env.UPDATE_INTERVAL) || 30000);
});
EOF

# ---- routes ----
mkdir -p routes
cat > routes/index.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');

router.get('/', (req, res) => {
  const status = db.getServerStatus();
  const topPlayers = db.getTopSearchedPlayers(5);
  const bestDeals = db.getBestDeals(5);
  res.render('index', { title: 'Dashboard', status, topPlayers, bestDeals });
});
module.exports = router;
EOF

cat > routes/players.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');
const api = require('../api');

router.get('/', async (req, res) => {
  const query = req.query.q || '';
  let player = null, error = null;
  if (query) {
    try {
      player = await api.getPlayer(query);
      db.recordPlayerSearch(query);
    } catch (e) { error = e.message; }
  }
  const topPlayers = db.getTopSearchedPlayers(5);
  res.render('player', { title: 'Player Search', query, player, error, topPlayers });
});
module.exports = router;
EOF

cat > routes/prices.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');
router.get('/', (req, res) => {
  res.render('prices', { title: 'Item Prices', prices: db.getPrices() });
});
module.exports = router;
EOF

cat > routes/auctions.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');

router.get('/', (req, res) => {
  const query = req.query.q || '';
  let auctions = [];
  if (query) {
    auctions = db.getAuctionsByItem(query);
    db.recordItemSearch(query);
  } else {
    auctions = db.getAuctions();
  }
  res.render('auctions', {
    title: 'Auctions',
    query,
    auctions,
    bestDeals: db.getBestDeals(5),
    topItems: db.getTopItems(5)
  });
});
module.exports = router;
EOF

cat > routes/leaderboards.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');

router.get('/:category?', (req, res) => {
  const category = req.params.category || 'money';
  const limit = parseInt(req.query.limit) || 10;
  const categories = db.getLeaderboardCategories();
  const available = categories.length ? categories : ['money','kills','playtime','mobs_killed','blocks_broken','blocks_placed','deaths','shards'];
  if (!available.includes(category)) return res.redirect(`/leaderboards/${available[0]}`);
  res.render('leaderboards', { title: 'Leaderboards', category, categories: available, entries: db.getLeaderboard(category, limit), limit });
});
module.exports = router;
EOF

cat > routes/bounties.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');

router.get('/', (req, res) => {
  const sort = req.query.sort || 'name_asc';
  res.render('bounties', { title: 'Bounties', bounties: db.getBounties(sort), sort });
});
module.exports = router;
EOF

cat > routes/orders.js << 'EOF'
const express = require('express');
const router = express.Router();
const db = require('../db');

router.get('/', (req, res) => {
  res.render('orders', {
    title: 'Orders',
    orders: db.getOrders(),
    topWanted: db.getTopWantedItems(5)
  });
});
module.exports = router;
EOF

cat > routes/teams.js << 'EOF'
const express = require('express');
const router = express.Router();
const api = require('../api');

router.get('/', async (req, res) => {
  const query = req.query.q || '';
  let team = null, error = null;
  if (query) {
    try { team = await api.getTeam(query); }
    catch (e) { error = e.message; }
  }
  res.render('team', { title: 'Team Search', query, team, error });
});
module.exports = router;
EOF

# ---- views ----
mkdir -p views
cat > views/layout.ejs << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><%= title %> · Bagel SMP</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:opsz,wght@14..32,400;14..32,600;14..32,700;14..32,800&display=swap" rel="stylesheet">
    <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { background:#0f0f0f; color:#d4d4d4; font-family:'Inter',system-ui,sans-serif; padding:20px; line-height:1.5; }
        a { color:#f7a64a; text-decoration:none; }
        a:hover { text-decoration:underline; }
        .container { max-width:1300px; margin:0 auto; }
        .topbar { display:flex; align-items:center; justify-content:space-between; background:#181818; border:1px solid #2a2a2a; border-radius:16px; padding:12px 24px; margin-bottom:28px; flex-wrap:wrap; gap:12px; }
        .topbar .brand { font-size:22px; font-weight:800; color:#fff; letter-spacing:-0.5px; }
        .topbar .brand span { color:#f7a64a; }
        .topbar .status { display:flex; align-items:center; gap:10px; font-size:14px; font-weight:600; }
        .status .dot { width:12px; height:12px; border-radius:50%; display:inline-block; background:<%= serverStatus.online ? '#5fb85a' : '#e5534b' %>; box-shadow:0 0 6px <%= serverStatus.online ? '#5fb85a88' : '#e5534b88' %>; }
        .status .players-badge { background:#2a2a2a; padding:2px 12px; border-radius:20px; font-size:13px; color:#b0b0b0; }
        .topbar .nav { display:flex; gap:4px; flex-wrap:wrap; }
        .topbar .nav a { color:#9aa0a6; padding:6px 14px; border-radius:8px; font-size:14px; font-weight:600; transition:0.2s; text-decoration:none; }
        .topbar .nav a:hover, .topbar .nav a.active { background:#2a2a2a; color:#fff; }
        .card { background:#181818; border:1px solid #282828; border-radius:16px; padding:22px 24px; margin-bottom:28px; transition:border-color 0.2s; }
        .card:hover { border-color:#f7a64a44; }
        .card-title { font-size:20px; font-weight:700; color:#fff; display:flex; align-items:center; gap:12px; margin-bottom:16px; flex-wrap:wrap; }
        .card-title .badge { font-size:11px; font-weight:700; background:#f7a64a22; color:#f7a64a; padding:2px 12px; border-radius:20px; letter-spacing:0.3px; }
        .card-title .badge-gray { background:#2a2a2a; color:#9aa0a6; }
        .grid-2 { display:grid; grid-template-columns:1fr 1fr; gap:24px; }
        .grid-3 { display:grid; grid-template-columns:repeat(3,1fr); gap:20px; }
        .grid-4 { display:grid; grid-template-columns:repeat(4,1fr); gap:16px; }
        .grid-5 { display:grid; grid-template-columns:repeat(5,1fr); gap:14px; }
        @media (max-width:900px) { .grid-2,.grid-3,.grid-4,.grid-5 { grid-template-columns:1fr 1fr; } }
        @media (max-width:600px) { .grid-2,.grid-3,.grid-4,.grid-5 { grid-template-columns:1fr; } }
        .search-bar { display:flex; gap:12px; flex-wrap:wrap; margin-bottom:18px; }
        .search-bar input, .search-bar select { background:#0c0c0c; border:1px solid #2a2a2a; border-radius:10px; padding:10px 16px; color:#fff; font-size:14px; outline:none; transition:0.2s; flex:1 1 180px; min-width:140px; }
        .search-bar input:focus, .search-bar select:focus { border-color:#f7a64a; box-shadow:0 0 0 3px #f7a64a22; }
        .search-bar button { background:#f7a64a; color:#1a1207; border:none; border-radius:10px; padding:10px 28px; font-weight:700; font-size:14px; cursor:pointer; transition:0.2s; }
        .search-bar button:hover { background:#ffc974; }
        .table-wrap { overflow-x:auto; }
        table { width:100%; border-collapse:collapse; font-size:14px; }
        th { text-align:left; padding:12px 8px 8px 8px; color:#70757a; font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:0.04em; border-bottom:1px solid #2a2a2a; }
        td { padding:10px 8px; border-bottom:1px solid #222; }
        tr:hover td { background:#1e1e1e; }
        .clickable { cursor:pointer; color:#f7a64a; font-weight:600; }
        .clickable:hover { text-decoration:underline; }
        .item-icon { display:inline-flex; align-items:center; gap:10px; }
        .item-icon img { width:36px; height:36px; image-rendering:pixelated; background:#0a0a0a; border-radius:4px; border:1px solid #333; flex-shrink:0; }
        .tag { display:inline-block; padding:2px 12px; border-radius:20px; font-size:12px; font-weight:600; }
        .tag-green { background:#5fb85a22; color:#7cd177; }
        .tag-red { background:#e5534b22; color:#f0796f; }
        .tag-gold { background:#f7a64a22; color:#f7a64a; }
        .tag-gray { background:#2a2a2a; color:#9aa0a6; }
        .stat-box { background:#0c0c0c; border-radius:12px; padding:14px; text-align:center; }
        .stat-box .label { color:#70757a; font-size:13px; }
        .stat-box .value { color:#fff; font-weight:700; font-size:18px; margin-top:2px; }
        .text-muted { color:#70757a; }
        .text-gold { color:#f7a64a; }
        .mt-8 { margin-top:8px; }
        .mb-8 { margin-bottom:8px; }
        .flex { display:flex; align-items:center; gap:12px; }
        .flex-between { display:flex; justify-content:space-between; align-items:center; }
        footer { text-align:center; padding:28px 0 12px; color:#575a68; font-size:13px; border-top:1px solid #222; margin-top:20px; }
        footer a { color:#f7a64a; }
    </style>
</head>
<body>
<div class="container">
    <header class="topbar">
        <div class="brand">🥯 <span>Bagel</span>SMP</div>
        <div class="status">
            <span class="dot"></span>
            <span><%= serverStatus.online ? 'Online' : 'Offline' %></span>
            <span class="players-badge"><%= serverStatus.players || 0 %> players</span>
            <span class="text-muted" style="font-size:12px; font-weight:400;">· 1.20.6</span>
        </div>
        <nav class="nav">
            <a href="/" class="<%= title === 'Dashboard' ? 'active' : '' %>">Dashboard</a>
            <a href="/players" class="<%= title === 'Player Search' ? 'active' : '' %>">Players</a>
            <a href="/auctions" class="<%= title === 'Auctions' ? 'active' : '' %>">Auctions</a>
            <a href="/prices" class="<%= title === 'Item Prices' ? 'active' : '' %>">Prices</a>
            <a href="/leaderboards" class="<%= title === 'Leaderboards' ? 'active' : '' %>">Leaderboards</a>
            <a href="/bounties" class="<%= title === 'Bounties' ? 'active' : '' %>">Bounties</a>
            <a href="/orders" class="<%= title === 'Orders' ? 'active' : '' %>">Orders</a>
            <a href="/teams" class="<%= title === 'Team Search' ? 'active' : '' %>">Teams</a>
        </nav>
    </header>
    <%- body %>
    <footer>
        Bagel SMP Live Dashboard &middot; Data sourced from <a href="https://bagelsmp.com/docs" target="_blank">official API</a> &middot; Item icons by <a href="https://www.minecraftitems.xyz/" target="_blank">MinecraftItems.xyz</a><br />
        <span style="font-size:12px; color:#424549;">Not affiliated with Mojang or Microsoft</span>
    </footer>
</div>
</body>
</html>
EOF

cat > views/index.ejs << 'EOF'
<% const { status, topPlayers, bestDeals } = locals; %>
<div class="card">
  <div class="card-title">📊 Dashboard <span class="badge">Live</span></div>
  <div class="grid-3">
    <div class="stat-box"><div class="label">Server Status</div><div class="value"><%= status.online ? '✅ Online' : '❌ Offline' %></div></div>
    <div class="stat-box"><div class="label">Players Online</div><div class="value"><%= status.players %></div></div>
    <div class="stat-box"><div class="label">Last Update</div><div class="value"><%= new Date(status.updated_at * 1000).toLocaleTimeString() %></div></div>
  </div>
</div>
<div class="grid-2">
  <div class="card">
    <div class="card-title">🔥 Top Searched Players <span class="badge">24h</span></div>
    <ul style="list-style:none;">
      <% topPlayers.forEach(p => { %>
        <li style="padding:6px 0; border-bottom:1px solid #222; display:flex; justify-content:space-between;">
          <a href="/players?q=<%= encodeURIComponent(p.player_name) %>" class="clickable"><%= p.player_name %></a>
          <span class="text-muted"><%= p.count %> searches</span>
        </li>
      <% }) %>
      <% if (topPlayers.length === 0) { %><li class="text-muted">No searches yet</li><% } %>
    </ul>
  </div>
  <div class="card">
    <div class="card-title">⭐ Best Deals <span class="badge">Auctions</span></div>
    <ul style="list-style:none;">
      <% bestDeals.forEach(a => { %>
        <li style="padding:6px 0; border-bottom:1px solid #222; display:flex; justify-content:space-between;">
          <span class="item-icon"><img src="<%= itemIconBase %>/<%= a.item_name.replace(/ /g, '_') %>/size=2" alt="<%= a.item_name %>" /><%= a.item_name %></span>
          <span class="text-gold">$<%= a.buy_now %></span>
        </li>
      <% }) %>
      <% if (bestDeals.length === 0) { %><li class="text-muted">No auctions</li><% } %>
    </ul>
  </div>
</div>
EOF

cat > views/player.ejs << 'EOF'
<% const { query, player, error, topPlayers } = locals; %>
<div class="card">
  <div class="card-title">🔍 Player Search <span class="badge">Overview</span></div>
  <form class="search-bar" method="get" action="/players">
    <input type="text" name="q" placeholder="Enter player name..." value="<%= query %>" />
    <button type="submit">Search</button>
  </form>
  <% if (error) { %>
    <div class="card" style="background:#2a0a0a; border-color:#e5534b44;"><p style="color:#f0796f;">⚠️ <%= error %></p></div>
  <% } %>
  <% if (player) { %>
    <div style="display:grid; grid-template-columns: 1fr 2fr; gap:24px;">
      <div><div class="stat-box" style="padding:20px;"><div style="font-size:56px;">⛏️</div><div style="font-size:24px; font-weight:800; color:#fff;"><%= player.name %></div><div class="text-muted"><%= player.type || 'Java' %> · <%= player.rankId || 'Default' %></div><div style="margin-top:12px; display:flex; gap:10px; justify-content:center; flex-wrap:wrap;"><span class="tag tag-green">💰 $<%= player.money ? (player.money/100).toFixed(2) : '0' %>M</span><span class="tag tag-gold">⏱️ <%= player.playtime ? Math.floor(player.playtime/3600) : 0 %>h</span></div></div></div>
      <div><div class="grid-2" style="gap:10px;"><div class="stat-box"><div class="label">Kills</div><div class="value"><%= player.kills || 0 %></div></div><div class="stat-box"><div class="label">Deaths</div><div class="value"><%= player.deaths || 0 %></div></div><div class="stat-box"><div class="label">Blocks Broken</div><div class="value"><%= player.blocks_broken || 0 %></div></div><div class="stat-box"><div class="label">Blocks Placed</div><div class="value"><%= player.blocks_placed || 0 %></div></div></div><div style="margin-top:12px; background:#0c0c0c; border-radius:10px; padding:12px;"><div class="flex-between"><span class="text-muted">Team</span><span style="color:#fff;"><%= player.team || 'None' %></span></div><div class="flex-between"><span class="text-muted">Joined</span><span style="color:#fff;"><%= player.joined ? new Date(player.joined).toLocaleDateString() : 'Unknown' %></span></div><div class="flex-between"><span class="text-muted">Last seen</span><span style="color:#fff;"><%= player.last_seen ? new Date(player.last_seen * 1000).toLocaleString() : 'Unknown' %></span></div></div></div>
    </div>
  <% } else if (query && !error) { %><p class="text-muted">No player found for "<%= query %>"</p><% } %>
  <div style="margin-top:20px; border-top:1px solid #2a2a2a; padding-top:16px;">
    <div class="flex-between"><span style="font-weight:600; color:#fff;">🔥 Top searched players</span><span class="text-muted" style="font-size:12px;">last 24h</span></div>
    <div class="grid-5" style="margin-top:10px;">
      <% topPlayers.forEach(p => { %>
        <div class="stat-box"><div class="label"><a href="/players?q=<%= encodeURIComponent(p.player_name) %>" class="clickable"><%= p.player_name %></a></div><div class="value" style="font-size:15px;"><%= p.count %> searches</div></div>
      <% }) %>
      <% if (topPlayers.length === 0) { %><div class="text-muted">No data yet</div><% } %>
    </div>
  </div>
</div>
EOF

cat > views/prices.ejs << 'EOF'
<% const { prices } = locals; %>
<div class="card">
  <div class="card-title">💰 Item Prices <span class="badge">Live</span></div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Item</th><th>Price (USD)</th><th>Change</th></tr></thead>
      <tbody>
        <% prices.forEach(item => { %>
          <tr><td><span class="item-icon"><img src="<%= itemIconBase %>/<%= item.item_name.replace(/ /g, '_') %>/size=2" alt="<%= item.item_name %>" /><%= item.item_name %></span></td><td>$<%= item.price_usd.toFixed(2) %></td><td><% if (item.change_percent > 0) { %><span class="tag tag-green">▲ <%= item.change_percent.toFixed(1) %>%</span><% } else if (item.change_percent < 0) { %><span class="tag tag-red">▼ <%= Math.abs(item.change_percent).toFixed(1) %>%</span><% } else { %><span class="tag tag-gray">—</span><% } %></td></tr>
        <% }) %>
        <% if (prices.length === 0) { %><tr><td colspan="3" class="text-muted" style="text-align:center;">No price data yet</td></tr><% } %>
      </tbody>
    </table>
  </div>
</div>
EOF

cat > views/auctions.ejs << 'EOF'
<% const { query, auctions, bestDeals, topItems } = locals; %>
<div class="card">
  <div class="card-title">🏷️ Auctions <span class="badge">Best deals</span></div>
  <form class="search-bar" method="get" action="/auctions">
    <input type="text" name="q" placeholder="Search item..." value="<%= query %>" />
    <button type="submit">Search</button>
  </form>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Item</th><th>Starting bid</th><th>Buy now</th><th>Seller</th></tr></thead>
      <tbody>
        <% auctions.forEach(a => { %>
          <tr><td><span class="item-icon"><img src="<%= itemIconBase %>/<%= a.item_name.replace(/ /g, '_') %>/size=2" alt="<%= a.item_name %>" /><%= a.item_name %></span></td><td>$<%= a.starting_bid %></td><td><%= a.buy_now ? '$' + a.buy_now : '—' %></td><td><%= a.seller %></td></tr>
        <% }) %>
        <% if (auctions.length === 0) { %><tr><td colspan="4" style="text-align:center; color:#70757a; padding:20px;"><%= query ? `No auctions found for "${query}"` : 'No auctions available' %></td></tr><% } %>
      </tbody>
    </table>
  </div>
  <div style="margin-top:14px; border-top:1px solid #2a2a2a; padding-top:12px;">
    <div class="flex-between"><span style="font-weight:600; color:#fff;">⭐ Best deals</span><span class="text-muted" style="font-size:12px;">lowest buy‑now</span></div>
    <div class="grid-5" style="margin-top:8px; gap:10px;">
      <% bestDeals.forEach(a => { %>
        <div class="stat-box"><div class="label"><%= a.item_name %></div><div class="value" style="font-size:15px;">$<%= a.buy_now %></div></div>
      <% }) %>
      <% if (bestDeals.length === 0) { %><div class="text-muted">No deals</div><% } %>
    </div>
  </div>
  <div style="margin-top:14px; border-top:1px solid #2a2a2a; padding-top:12px;">
    <div class="flex-between"><span style="font-weight:600; color:#fff;">🔥 Top searched items</span><span class="text-muted" style="font-size:12px;">from auction searches</span></div>
    <div class="grid-5" style="margin-top:8px;">
      <% topItems.forEach(item => { %>
        <div class="stat-box"><div class="label"><%= item.item_name %></div><div class="value" style="font-size:15px;"><%= item.search_count %> searches</div></div>
      <% }) %>
      <% if (topItems.length === 0) { %><div class="text-muted">No statistics yet</div><% } %>
    </div>
  </div>
</div>
EOF

cat > views/leaderboards.ejs << 'EOF'
<% const { category, categories, entries, limit } = locals; %>
<div class="card">
  <div class="card-title">
    🏆 Leaderboards <span class="badge"><%= category.charAt(0).toUpperCase() + category.slice(1) %></span>
    <% categories.forEach(c => { %>
      <a href="/leaderboards/<%= c %>?limit=<%= limit %>" class="badge badge-gray" style="cursor:pointer; text-decoration:none;"><%= c.charAt(0).toUpperCase() + c.slice(1) %></a>
    <% }) %>
  </div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>#</th><th>Player</th><th>Value</th><th>Team</th></tr></thead>
      <tbody>
        <% entries.forEach(entry => { %>
          <tr><td><%= entry.rank %></td><td><a href="/players?q=<%= encodeURIComponent(entry.name) %>" class="clickable"><%= entry.name %></a></td><td><% if (category === 'money') { %>$<%= entry.value.toLocaleString() %><% } else { %><%= entry.value.toLocaleString() %><% } %></td><td><%= entry.rank_id || '—' %></td></tr>
        <% }) %>
        <% if (entries.length === 0) { %><tr><td colspan="4" class="text-muted" style="text-align:center;">No data yet</td></tr><% } %>
      </tbody>
    </table>
  </div>
  <div class="flex-between" style="margin-top:12px;">
    <span class="text-muted">Showing top <%= limit %></span>
    <div><a href="?limit=10" class="badge badge-gray">10</a><a href="?limit=25" class="badge badge-gray">25</a><a href="?limit=50" class="badge badge-gray">50</a><a href="?limit=100" class="badge badge-gray">100</a></div>
  </div>
</div>
EOF

cat > views/bounties.ejs << 'EOF'
<% const { bounties, sort } = locals; %>
<div class="card">
  <div class="card-title">🎯 Bounties <span class="badge">Active</span></div>
  <form class="search-bar" method="get" action="/bounties">
    <select name="sort">
      <option value="name_asc" <%= sort === 'name_asc' ? 'selected' : '' %>>Player A → Z</option>
      <option value="price_desc" <%= sort === 'price_desc' ? 'selected' : '' %>>Price High → Low</option>
      <option value="price_asc" <%= sort === 'price_asc' ? 'selected' : '' %>>Price Low → High</option>
    </select>
    <button type="submit">Sort</button>
  </form>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Target</th><th>Bounty</th><th>Placed by</th></tr></thead>
      <tbody>
        <% bounties.forEach(b => { %>
          <tr><td><a href="/players?q=<%= encodeURIComponent(b.target) %>" class="clickable"><%= b.target %></a></td><td>$<%= b.amount %></td><td><%= b.placed_by %></td></tr>
        <% }) %>
        <% if (bounties.length === 0) { %><tr><td colspan="3" class="text-muted" style="text-align:center;">No bounties</td></tr><% } %>
      </tbody>
    </table>
  </div>
</div>
EOF

cat > views/orders.ejs << 'EOF'
<% const { orders, topWanted } = locals; %>
<div class="card">
  <div class="card-title">📦 Orders <span class="badge">To deliver</span></div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Item</th><th>Qty</th><th>Unit price</th><th>Buyer</th></tr></thead>
      <tbody>
        <% orders.forEach(o => { %>
          <tr><td><span class="item-icon"><img src="<%= itemIconBase %>/<%= o.item_name.replace(/ /g, '_') %>/size=2" alt="<%= o.item_name %>" /><%= o.item_name %></span></td><td><%= o.quantity %></td><td>$<%= o.unit_price %></td><td><%= o.buyer %></td></tr>
        <% }) %>
        <% if (orders.length === 0) { %><tr><td colspan="4" class="text-muted" style="text-align:center;">No orders</td></tr><% } %>
      </tbody>
    </table>
  </div>
  <div style="margin-top:14px; border-top:1px solid #2a2a2a; padding-top:12px;">
    <div class="flex-between"><span style="font-weight:600; color:#fff;">🔥 Top 5 wanted items</span><span class="text-muted" style="font-size:12px;">by search count</span></div>
    <div class="grid-5" style="margin-top:8px;">
      <% topWanted.forEach(item => { %>
        <div class="stat-box"><div class="label"><%= item.item_name %></div><div class="value" style="font-size:15px;"><%= item.search_count %> orders</div></div>
      <% }) %>
      <% if (topWanted.length === 0) { %><div class="text-muted">No statistics yet</div><% } %>
    </div>
  </div>
</div>
EOF

cat > views/team.ejs << 'EOF'
<% const { query, team, error } = locals; %>
<div class="card">
  <div class="card-title">🏳️‍🌈 Team Search <span class="badge">Overview</span></div>
  <form class="search-bar" method="get" action="/teams">
    <input type="text" name="q" placeholder="Enter team name..." value="<%= query %>" />
    <button type="submit">Search</button>
  </form>
  <% if (error) { %>
    <div class="card" style="background:#2a0a0a; border-color:#e5534b44;"><p style="color:#f0796f;">⚠️ <%= error %></p></div>
  <% } %>
  <% if (team) { %>
    <div style="display:grid; grid-template-columns: 1fr 2fr; gap:20px;">
      <div class="stat-box" style="padding:18px;"><div style="font-size:48px;">🏳️‍🌈</div><div style="font-size:22px; font-weight:800; color:#fff;"><%= team.name %></div><div class="text-muted">Founded: <%= team.founded ? new Date(team.founded).toLocaleDateString() : 'Unknown' %></div><div style="margin-top:10px;"><span class="tag tag-gold">🏆 <%= team.wins || 0 %> wins</span></div></div>
      <div><div class="grid-2" style="gap:10px;"><div class="stat-box"><div class="label">Members</div><div class="value"><%= team.members ? team.members.length : 0 %></div></div><div class="stat-box"><div class="label">Total Kills</div><div class="value"><%= team.total_kills || 0 %></div></div><div class="stat-box"><div class="label">Total Value</div><div class="value">$<%= team.total_value ? team.total_value.toLocaleString() : '0' %></div></div><div class="stat-box"><div class="label">Leader</div><div class="value" style="font-size:16px;"><%= team.leader || '—' %></div></div></div><div style="margin-top:10px; background:#0c0c0c; border-radius:8px; padding:10px;"><span class="text-muted">Members: </span><span style="color:#fff;"><%= team.members ? team.members.join(', ') : 'None' %></span></div></div>
    </div>
  <% } else if (query && !error) { %><p class="text-muted">No team found for "<%= query %>"</p><% } %>
</div>
EOF

cat > views/404.ejs << 'EOF'
<div class="card" style="text-align:center; padding:60px 20px;">
    <h1 style="font-size:80px; color:#f7a64a;">404</h1>
    <p style="font-size:24px; color:#fff;">Page not found</p>
    <a href="/" class="badge badge-gold" style="display:inline-block; margin-top:20px;">Go to Dashboard</a>
</div>
EOF

# ---- public/ (empty for now, but create) ----
mkdir -p public
touch public/.gitkeep

# ---- permissions ----
chown -R $SUDO_USER:$SUDO_USER "$PROJECT_DIR" 2>/dev/null || true

echo ""
echo "✅ Project created at $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_DIR"
echo "  2. Edit .env and set your BAGEL_API_KEY"
echo "  3. npm install"
echo "  4. npm start"
echo ""
echo "Then visit http://localhost:3004"
