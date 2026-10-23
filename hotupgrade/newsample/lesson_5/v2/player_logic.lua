local count = 0
local M =
{
    new_tag = "only-v2",
    settings = {bonus = 21},
}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "剑" and 21 or 0)
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