// Re-records the API fixtures the tests use.
//
// It drives the server's real API code (lib/api.js in horinezachary/shoppingList) against that
// repo's in-memory fake database and saves every response as JSON, so the tests check the
// app against what the server actually sends, not against what the docs say.
//
//   git clone https://github.com/horinezachary/shoppingList ../shoppingList
//   (cd ../shoppingList && git checkout mobile-api && npm ci)
//   node scripts/capture-fixtures.js [outputDir]
//
// SHOPPINGLIST_DIR points at the server checkout (default: ../shoppingList).
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const REPO = path.resolve(process.env.SHOPPINGLIST_DIR || path.join(__dirname, '..', '..', 'shoppingList'));
const OUT = path.resolve(process.argv[2] || path.join(__dirname, '..', 'Tests', 'LorisListKitTests', 'Fixtures'));
fs.mkdirSync(OUT, { recursive: true });

// Pull the harness() function out of test/api.js without running that file's tests.
const src = fs.readFileSync(path.join(REPO, 'test/api.js'), 'utf8');
const start = src.indexOf('function harness()');
const end = src.indexOf('async function main()');
const quote = (v) => "'" + v + "'";
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const mk = new Function(
  'require', 'assert', 'quote', 'MINUTE', 'HOUR', 'passwordsLib', 'apiTokens', 'apiLib', 'createLimiter', 'failureKeys', 'fakeDb', 'fakeBcrypt',
  src.slice(start, end) + '\nreturn harness;'
);
const req = (p) => require(path.join(REPO, p));
const fakeBcrypt = {
  hash: async (pw) => 'h$' + pw,
  compare: async (pw, stored) => stored === 'h$' + pw
};
const harness = mk(
  require, assert, quote, MINUTE, HOUR,
  req('lib/passwords'), req('lib/apiTokens'), req('lib/api'),
  req('lib/rateLimit').createLimiter, req('lib/rateLimit').failureKeys, req('test/fakeDb'), fakeBcrypt
);

const saved = [];
function save(name, r) {
  const doc = { status: r.status };
  if (r.body !== undefined) { doc.body = r.body; }
  if (r.headers && Object.keys(r.headers).length) { doc.headers = r.headers; }
  fs.writeFileSync(path.join(OUT, name + '.json'), JSON.stringify(doc, null, 2) + '\n');
  saved.push(name + ' -> ' + r.status);
  return r;
}

(async () => {
  const h = harness();
  const call = h.call;

  save('root', await call('get', '/'));

  // --- registration + sign in -------------------------------------------------
  const reg = save('register_created', await call('post', '/auth/register', {
    body: { firstName: 'Lori', lastName: 'Horine', username: 'lori', email: 'lori@example.com', password: 'hunter2hunter2', deviceName: "Lori's iPhone" }
  }));
  save('register_username_taken', await call('post', '/auth/register', {
    body: { firstName: 'X', lastName: 'Y', username: 'lori', email: 'other@example.com', password: 'hunter2hunter2' }
  }));
  save('register_email_in_use', await call('post', '/auth/register', {
    body: { firstName: 'X', lastName: 'Y', username: 'other', email: 'lori@example.com', password: 'hunter2hunter2' }
  }));
  save('register_invalid', await call('post', '/auth/register', {
    body: { firstName: 'X', lastName: 'Y', username: 'bad name!', email: 'nope', password: 'short' }
  }));

  const login = save('login_ok', await call('post', '/auth/login', {
    body: { username: 'lori', password: 'hunter2hunter2', deviceName: "Lori's iPhone" }
  }));
  let token = login.body.accessToken;
  const refresh = login.body.refreshToken;
  save('login_invalid_credentials', await call('post', '/auth/login', { body: { username: 'lori', password: 'wrong-wrong' } }));
  save('login_missing_fields', await call('post', '/auth/login', { body: { username: 'lori' } }));

  // a refresh replaces the session's access token: the old one stops working at once
  save('me_before_refresh', await call('get', '/me', { token }));
  const refreshed = save('refresh_ok', await call('post', '/auth/refresh', { body: { refreshToken: refresh } }));
  save('me_with_replaced_token', await call('get', '/me', { token }));
  token = refreshed.body.accessToken;
  save('refresh_invalid', await call('post', '/auth/refresh', { body: { refreshToken: 'not-a-real-token' } }));

  // --- profile ----------------------------------------------------------------
  save('me', await call('get', '/me', { token }));
  save('me_unauthorized', await call('get', '/me', {}));
  save('me_patched', await call('patch', '/me', { token, body: { firstName: 'Lorraine', showTips: false } }));
  save('me_patch_invalid', await call('patch', '/me', { token, body: { email: 'not-an-email' } }));
  save('password_wrong_current', await call('put', '/me/password', { token, body: { currentPassword: 'definitely-wrong', newPassword: 'abcdefgh12' } }));
  save('password_too_short', await call('put', '/me/password', { token, body: { currentPassword: 'hunter2hunter2', newPassword: 'abc' } }));

  // --- colours, lists, items --------------------------------------------------
  save('colors', await call('get', '/colors', { token }));
  save('lists_empty', await call('get', '/lists', { token }));
  const created = save('list_created', await call('post', '/lists', { token, body: { name: 'Groceries', color: '#ff9900' } }));
  const id = String(created.body.list.id);
  save('list_create_invalid', await call('post', '/lists', { token, body: { name: '', color: 'zzz' } }));
  const second = await call('post', '/lists', { token, body: { name: 'Hardware', color: '3366cc' } });
  save('lists_two', await call('get', '/lists', { token }));

  save('item_added_with_count', await call('post', '/lists/:id/items', { token, params: { id }, body: { name: 'Milk', count: 2 } }));
  save('item_added_no_count', await call('post', '/lists/:id/items', { token, params: { id }, body: { name: 'Bread' } }));
  const afterAdd = save('item_added_third', await call('post', '/lists/:id/items', { token, params: { id }, body: { name: 'Eggs', count: 12 } }));
  save('item_add_invalid', await call('post', '/lists/:id/items', { token, params: { id }, body: { name: '', count: 0 } }));
  const itemId = String(afterAdd.body.items[0].id);
  save('item_checked', await call('patch', '/lists/:id/items/:itemId', { token, params: { id, itemId }, body: { checked: true } }));
  save('list_with_items', await call('get', '/lists/:id', { token, params: { id } }));
  save('list_not_found', await call('get', '/lists/:id', { token, params: { id: '99999' } }));
  save('list_renamed', await call('patch', '/lists/:id', { token, params: { id }, body: { name: 'Weekly Groceries' } }));
  save('suggestions', await call('get', '/items/suggestions', { token }));
  save('items_clear_requires_true', await call('delete', '/lists/:id/items', { token, params: { id }, query: {} }));
  save('items_cleared', await call('delete', '/lists/:id/items', { token, params: { id }, query: { checked: 'true' } }));
  const remaining = (await call('get', '/lists/:id', { token, params: { id } })).body.list.items[0];
  save('item_removed', await call('delete', '/lists/:id/items/:itemId', { token, params: { id, itemId: String(remaining.id) } }));

  // --- sessions ---------------------------------------------------------------
  await call('post', '/auth/login', { body: { username: 'lori', password: 'hunter2hunter2', deviceName: 'Pixel 9' } });
  save('sessions', await call('get', '/auth/sessions', { token }));

  // --- sharing ----------------------------------------------------------------
  await h.addUser('amy');
  await h.addUser('bob');
  const amy = await h.signIn('amy');
  const bob = await h.signIn('bob');
  await call('post', '/lists/:id/items', { token, params: { id }, body: { name: 'Cake' } });
  save('share_sent', await call('post', '/lists/:id/shares', { token, params: { id }, body: { email: 'amy@example.com', permission: 'edit' } }));
  await call('post', '/lists/:id/shares', { token, params: { id }, body: { email: 'bob@example.com', permission: 'view' } });
  save('share_invalid_email', await call('post', '/lists/:id/shares', { token, params: { id }, body: { email: 'nope', permission: 'edit' } }));
  const amyKey = /([0-9a-f]{32})$/.exec(h.mail[0].context.link)[1];
  const bobKey = /([0-9a-f]{32})$/.exec(h.mail[1].context.link)[1];
  save('share_peek', await call('get', '/shares/:key', { token: amy.accessToken, params: { key: amyKey } }));
  save('share_accepted', await call('post', '/shares/:key', { token: amy.accessToken, params: { key: amyKey }, body: { response: 'accept' } }));
  save('share_accept_twice', await call('post', '/shares/:key', { token: amy.accessToken, params: { key: amyKey }, body: { response: 'accept' } }));
  save('share_denied', await call('post', '/shares/:key', { token: bob.accessToken, params: { key: bobKey }, body: { response: 'deny' } }));
  const bob2 = await h.call('post', '/lists/:id/shares', { token, params: { id }, body: { email: 'bob@example.com', permission: 'view' } });
  const bobKey2 = /([0-9a-f]{32})$/.exec(h.mail[h.mail.length - 1].context.link)[1];
  await call('post', '/shares/:key', { token: bob.accessToken, params: { key: bobKey2 }, body: { response: 'accept' } });
  save('lists_shared_with_amy', await call('get', '/lists', { token: amy.accessToken }));
  save('list_as_viewer', await call('get', '/lists/:id', { token: bob.accessToken, params: { id } }));
  save('viewer_add_forbidden', await call('post', '/lists/:id/items', { token: bob.accessToken, params: { id }, body: { name: 'Nope' } }));
  save('editor_rename_forbidden', await call('patch', '/lists/:id', { token: amy.accessToken, params: { id }, body: { name: 'Mine now' } }));
  save('leave_list', await call('delete', '/lists/:id/members/me', { token: amy.accessToken, params: { id } }));
  save('leave_own_list', await call('delete', '/lists/:id/members/me', { token, params: { id } }));
  save('list_deleted', await call('delete', '/lists/:id', { token, params: { id: String(second.body.list.id) } }));

  // --- sync: the change digest, and what the live stream sends ----------------
  save('list_synced', await call('get', '/lists/:id', { token, params: { id } }));
  save('changes_synced', await call('get', '/changes', { token }));
  save('changes_empty', await call('get', '/changes', { token: amy.accessToken }));
  const added = await call('post', '/lists/:id/items', { token, params: { id }, body: { name: 'Oat milk', count: 3 } });
  save('item_added_for_sync', added);
  save('list_after_add', await call('get', '/lists/:id', { token, params: { id } }));
  save('changes_after_add', await call('get', '/changes', { token }));
  {
    const { EventEmitter } = require('events');
    const events = require(path.join(REPO, 'lib/apiEvents')).create({ api: h.api, setInterval: () => null });
    const res = new EventEmitter();
    res.written = '';
    res.status = () => res;
    res.setHeader = () => {};
    res.flushHeaders = () => {};
    res.write = (t) => { res.written += t; return true; };
    res.end = () => {};
    const request = new EventEmitter();
    request.headers = { authorization: 'Bearer ' + token };
    await events.handle(request, res, (e) => { throw e; });
    await call('post', '/lists/:id/items', { token, params: { id }, body: { name: 'Bread' } });
    await events.tick();
    fs.writeFileSync(path.join(OUT, 'events_stream.txt'), res.written);
    saved.push('events_stream.txt');
    res.emit('close');
  }

  // --- password reset, rate limiting, sign out --------------------------------
  save('password_reset_requested', await call('post', '/auth/password-reset', { body: { email: 'lori@example.com' } }));
  // The reset link goes out by email; the harness keeps the mail, so the token can be read back.
  const resetToken = /([0-9a-f]{32})$/.exec(h.mail[h.mail.length - 1].context.link)[1];
  save('password_reset_token_unknown', await call('get', '/auth/password-reset/:token', { params: { token: 'f'.repeat(32) } }));
  for (let i = 0; i < 5; i++) {
    await call('post', '/auth/login', { body: { username: 'amy', password: 'wrong-' + i }, ip: '203.0.113.9' });
  }
  save('login_rate_limited', await call('post', '/auth/login', { body: { username: 'amy', password: 'wrong-again' }, ip: '203.0.113.9' }));
  const sess = (await call('get', '/auth/sessions', { token })).body.sessions;
  const other = sess.find((s) => !s.current);
  save('session_revoked', await call('delete', '/auth/sessions/:sessionId', { token, params: { sessionId: String(other.id) } }));
  save('session_not_found', await call('delete', '/auth/sessions/:sessionId', { token, params: { sessionId: '424242' } }));
  save('logout', await call('post', '/auth/logout', { token }));
  save('after_logout_unauthorized', await call('get', '/lists', { token }));

  // --- finishing a reset (last, because it signs the account out everywhere) ----
  save('password_reset_token_ok', await call('get', '/auth/password-reset/:token', { params: { token: resetToken } }));
  save('password_reset_weak_password', await call('put', '/auth/password-reset/:token', { params: { token: resetToken }, body: { password: 'short' } }));
  save('password_reset_completed', await call('put', '/auth/password-reset/:token', { params: { token: resetToken }, body: { password: 'a-brand-new-password' } }));
  save('password_reset_token_used', await call('get', '/auth/password-reset/:token', { params: { token: resetToken } }));
  save('share_not_found', await call('get', '/shares/:key', { token: amy.accessToken, params: { key: 'e'.repeat(32) } }));

  console.log(saved.join('\n'));
})().catch((e) => { console.error('CAPTURE FAILED', e); process.exit(1); });
