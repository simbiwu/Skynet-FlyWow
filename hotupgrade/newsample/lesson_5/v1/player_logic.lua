local count = 0
local M =
{
    legacy_tag = "only-v1",
    settings = {bonus = 5},
}

function M.version()
    return "v1"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "刀" and 5 or 0)
    end
end

function M.next_count()
    count = count + 1
    return count
end

function M.export_state()
    return {count = count}
end

function M.import_state(snapshot)
    count = snapshot.count
    return true
end

return M