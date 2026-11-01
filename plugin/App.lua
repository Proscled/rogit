--!strict
-- What the parts of the plugin call in each other where each would otherwise need the other loaded first: the main
-- panel and the actions behind its buttons, for example. The plugin's Script sets `plugin` before loading any part,
-- and each part fills in its own functions as it loads. Nothing is called until every part has loaded.

export type App = {
	plugin: Plugin,
	render: () -> (),
	openBranch: (string) -> (),
	startMerge: (string) -> (),
	setPinned: (string, boolean) -> (),
	confirmArchive: (string) -> (),
	openHistory: (any) -> (),
	viewCommit: (any, string) -> (),
	selectObject: (string) -> (),
	setStaged: ({ string }) -> (),
	discard: ({ string }) -> (),
	flushChanges: () -> boolean,
}

local App: App = {} :: any

return App
