local M = {}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        if state.equip == "剑" then
            return base_attack + 20 + 1
        end

        return base_attack
    end
end

return M