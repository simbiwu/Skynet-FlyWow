local skynet = require "skynet"

skynet.satart(function()
    local hotupgrade_service_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hot = require "flywow_hotupgrade"

    local root = os.getenv("HOTUPGRADE_LESSON_ROOT")
    local result = skynet.call(hotupgrade_service_handle, "lua", init,
    {
        patch_path = root .. "/patches",
            root_path = root .. "/host",
            service_path = "service",
    })

    if not result.ok then
         error(result.message)
    end

    local first_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_handle, "lua", init)
    if not initialized.ok then
        error(initialized.message)
    end

    end
    )
--[[skynet.start(function()


    local first_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_handle, "lua", "init")
    if not initialized.ok then
        error(initialized.message)
    end

    local response = skynet.call(first_handle, "lua", "inspect")
    local player = response.player

    print("handle:", player.handle)
    print("version:", player.version)
    print("equip:", player.equip)
    print("schema:", player.schema_version)
    print("attack:", player.attack)

    io.stdout:flush()
    os.exit(0)
end)]]
