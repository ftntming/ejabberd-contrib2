--
-- ejabberd, Copyright (C) 2002-2020   ProcessOne
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- General Public License for more details.
--
-- You should have received a copy of the GNU General Public License along
-- with this program; if not, write to the Free Software Foundation, Inc.,
-- 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
--

-- To update from the old schema, replace <HOST> with the host's domain:

-- ALTER TABLE irc_custom ADD COLUMN server_host text NOT NULL DEFAULT '<HOST>';
-- ALTER TABLE irc_custom ALTER COLUMN server_host DROP DEFAULT;

CREATE TABLE irc_custom (
    jid text NOT NULL,
    host text NOT NULL,
    server_host text NOT NULL,
    data text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX i_irc_custom_jid_host ON irc_custom USING btree (jid, host);
