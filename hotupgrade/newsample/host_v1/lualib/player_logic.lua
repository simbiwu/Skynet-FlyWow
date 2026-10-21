local M = {}

function M.version()
    return "v1"
end

function M.make_load(state)
    return function(base_attack)
        if state.equip == "刀" then
            return base_attack + 5
        end

        return base_attack
    end
end

return M