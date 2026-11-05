-- Radio 1965 Events DB
-- Run against a MySQL/MariaDB server, e.g.:
--  sudo mysql -u root -p < sql/schema.sql


-- NB! Replace __DB_PASSWORD__ with the actual password in the SQL commands below before running this script.

CREATE DATABASE IF NOT EXISTS radio65 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'radio65'@'localhost' IDENTIFIED BY '__DB_PASSWORD__';
GRANT ALL PRIVILEGES ON radio65.* TO 'radio65'@'localhost';
FLUSH PRIVILEGES;

USE radio65;

-- "Become a Contributor" accounts (project-description.md #10.2) - must
-- exist before `events` below, since events.author_id references it.
-- Plain auto-increment integer id (not Event's "evt_<ts>"-style string) -
-- easier to hand-edit/cross-reference directly in the DB.
-- email/password_hash/access_token are nullable - POST /contributors/delete
-- ("Leave contributor role" -> "Delete my data") scrubs all three and sets
-- role='deleted', keeping id/name so already-published events still
-- resolve a valid author.
CREATE TABLE IF NOT EXISTS users (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  name          VARCHAR(255) NOT NULL,
  email         VARCHAR(255) NULL UNIQUE,
  role          ENUM('pending','contributor','manager','banned','deleted') NOT NULL DEFAULT 'pending',
  password_hash VARCHAR(255) NULL,
  access_token  VARCHAR(64) NULL UNIQUE,
  reset_token   VARCHAR(64) NULL UNIQUE,
  reset_token_expires_at DATETIME NULL,
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS events (
  id               VARCHAR(64) PRIMARY KEY,
  type             ENUM('text','audio','video','article','webcontent','livestream','streamrecording') NOT NULL,
  title            VARCHAR(255) NOT NULL,
  summary          TEXT,
  url              VARCHAR(1024),
  publish_at       DATETIME NOT NULL,
  shelf_at         DATETIME NULL,
  status           ENUM('unpublished','new','shelved','archived') NOT NULL DEFAULT 'unpublished',
  payload          JSON NULL,
  -- Who posted this event - nullable, not yet populated by
  -- POST /events/publish (project-description.md #10.2/#10.3 - out of
  -- scope until the editor itself knows who's submitting).
  author_id        INT NULL,
  created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS tags (
  event_id VARCHAR(64) NOT NULL,
  tag      VARCHAR(64) NOT NULL,
  PRIMARY KEY (event_id, tag),
  FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE,
  INDEX idx_tag (tag)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- This file is a fresh-install bootstrap script, not applied incrementally
-- - an *existing* deployed DB (which already has `events` without
-- `author_id`, same situation as EVENT_TYPES growing over time) needs this
-- run by hand instead:
--   CREATE TABLE users (...);               -- the CREATE TABLE above
--   ALTER TABLE events ADD COLUMN author_id INT NULL,
--     ADD FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE SET NULL;
--
-- If you already created `users` with the old VARCHAR(64) "usr_<ts>" id
-- (before it switched to a plain auto-increment INT) and only have
-- throwaway test rows in it so far (author_id is never populated yet, so
-- there's nothing real depending on the old id values): events.author_id's
-- FK has to be dropped first - MySQL refuses to touch users.id while
-- anything still references it, even if every value is NULL.
--   SELECT CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE
--     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'events'
--       AND COLUMN_NAME = 'author_id' AND REFERENCED_TABLE_NAME = 'users';
--   ALTER TABLE events DROP FOREIGN KEY <name from the query above>;
--
-- Then either drop and recreate (simplest, loses existing rows):
--   DROP TABLE users;
--   CREATE TABLE users (...);               -- the CREATE TABLE above
-- ...or convert in place to keep existing rows:
--   ALTER TABLE users ADD COLUMN id_new INT AUTO_INCREMENT UNIQUE FIRST;
--   ALTER TABLE users DROP PRIMARY KEY, DROP COLUMN id,
--     CHANGE COLUMN id_new id INT AUTO_INCREMENT PRIMARY KEY;
--
-- Either way, finish by converting author_id to match and re-adding the FK:
--   ALTER TABLE events MODIFY COLUMN author_id INT NULL,
--     ADD FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE SET NULL;
--
-- If `users` already exists without reset_token/reset_token_expires_at
-- (added for the login + forgot-password flow):
--   ALTER TABLE users ADD COLUMN reset_token VARCHAR(64) NULL UNIQUE,
--     ADD COLUMN reset_token_expires_at DATETIME NULL;
--
-- If `users`'s email/password_hash/access_token are still NOT NULL and
-- its role enum doesn't have 'deleted' yet (added for POST
-- /contributors/delete - "Leave contributor role" -> "Delete my data"):
--   ALTER TABLE users
--     MODIFY COLUMN email VARCHAR(255) NULL,
--     MODIFY COLUMN password_hash VARCHAR(255) NULL,
--     MODIFY COLUMN access_token VARCHAR(64) NULL,
--     MODIFY COLUMN role ENUM('pending','contributor','manager','banned','deleted')
--       NOT NULL DEFAULT 'pending';
--
-- Comments feature removed entirely (never had any UI consuming it) and
-- the "audiostream"/"videostream" event types dropped (folded into
-- Audio/Video everywhere they were used - see app/CollectionPage.qml) -
-- on an already-deployed DB:
--   -- First check nothing actually uses the two types being removed -
--   -- MySQL would otherwise silently truncate those rows' `type` to ''
--   -- when the ALTER below runs, which violates the NOT NULL constraint
--   -- and fails the whole statement instead of quietly corrupting data,
--   -- but it's still worth migrating any real rows by hand first (e.g.
--   -- UPDATE events SET type='audio' WHERE type='audiostream'; and the
--   -- 'video' equivalent) rather than discovering this failure blind:
--   SELECT id, type FROM events WHERE type IN ('audiostream','videostream');
--
--   ALTER TABLE events DROP COLUMN comments_enabled;
--   ALTER TABLE events MODIFY COLUMN type
--     ENUM('text','audio','video','article','webcontent','livestream','streamrecording')
--     NOT NULL;
