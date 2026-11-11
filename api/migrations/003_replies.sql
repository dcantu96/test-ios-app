-- Write back: a capsule can answer one you've opened. It's sealed for as long as the one it answers waited.
alter table capsules add column if not exists reply_to uuid references capsules (id);
