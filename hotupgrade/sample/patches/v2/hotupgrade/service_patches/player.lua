--- 一次性 PlayerService Patch；返回完整迁移状态和要替换的业务函数。
return function(state)
    return
    {
        migrate = function(old_state)
            assert(old_state.schema_version == 1, "只支持从 schema 1 迁移")
            return
            {
                equip = "剑",
                level = old_state.level,
                schema_version = 2,
            }
        end,
        functions =
        {
            load = function(base_attack)
                return base_attack + (state.equip == "剑" and 20 or 0) + 1
            end,
        },
    }
end
