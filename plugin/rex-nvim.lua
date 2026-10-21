-- Registers the :Rex user command (deferred require). setup() re-registers
-- idempotently, covering eager, lazy, and daemon-injected installs alike.
require("rex-nvim.commands").register()
