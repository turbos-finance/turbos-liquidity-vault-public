module consumer::smoke { use turbos_assets_manage::config; public fun check(c: &config::GlobalConfig,a: address) { config::check_rebalance_manager_role(c,a) } }
