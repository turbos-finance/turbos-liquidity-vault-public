// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT
#[test_only]
module turbos_assets_manage::security_acl_tests {
    use turbos_assets_manage::config::{Self, AdminCap, GlobalConfig, OperatorCap};
    use turbos_assets_manage::router;
    use sui::test_scenario::{Self, Scenario};
    use sui::object;

    const ADMIN: address = @0xA;
    const USER: address = @0xB;

    fun setup(): (Scenario, AdminCap, GlobalConfig) {
        let s = test_scenario::begin(ADMIN);
        config::init_for_testing(test_scenario::ctx(&mut s));
        test_scenario::next_tx(&mut s, ADMIN);
        let cap = test_scenario::take_from_sender<AdminCap>(&s);
        let c = test_scenario::take_shared<GlobalConfig>(&s);
        router::set_package_version(&cap, &mut c, 4);
        (s, cap, c)
    }

    fun finish(s: Scenario, cap: AdminCap, c: GlobalConfig) {
        test_scenario::return_to_sender(&s, cap);
        test_scenario::return_shared(c);
        test_scenario::end(s);
    }

    #[test]
    fun security_each_granted_role_passes_its_check() {
        let (s, cap, c) = setup();
        router::set_roles(&cap, &mut c, USER, 7);
        config::check_vault_manager_role(&c, USER);
        config::check_reward_manager_role(&c, USER);
        config::check_rebalance_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 1, location = turbos_assets_manage::config)]
    fun security_missing_vault_role_is_rejected() {
        let (s, cap, c) = setup();
        config::check_vault_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 2, location = turbos_assets_manage::config)]
    fun security_missing_reward_role_is_rejected() {
        let (s, cap, c) = setup();
        config::check_reward_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 3, location = turbos_assets_manage::config)]
    fun security_missing_rebalance_role_is_rejected() {
        let (s, cap, c) = setup();
        config::check_rebalance_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 2, location = turbos_assets_manage::config)]
    fun security_revoked_reward_role_is_rejected() {
        let (s, cap, c) = setup();
        router::set_roles(&cap, &mut c, USER, 7);
        config::check_reward_manager_role(&c, USER);
        router::remove_role(&cap, &mut c, USER, 1);
        config::check_reward_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 1, location = turbos_assets_manage::config)]
    fun security_rebalance_only_does_not_grant_vault_management() {
        let (s, cap, c) = setup();
        router::set_roles(&cap, &mut c, USER, 4);
        config::check_rebalance_manager_role(&c, USER);
        config::check_vault_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 0, location = turbos_assets_manage::config)]
    fun security_future_version_blocks_acl_changes() {
        let (s, cap, c) = setup();
        router::set_package_version(&cap, &mut c, 5);
        router::set_roles(&cap, &mut c, USER, 7);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 0, location = turbos_assets_manage::config)]
    fun security_version_cannot_move_backwards() {
        let (s, cap, c) = setup();
        router::set_package_version(&cap, &mut c, 3);
        finish(s, cap, c);
    }

    #[test]
    fun security_operator_permissions_are_keyed_by_cap_id() {
        let (s, cap, c) = setup();
        router::add_operator(&cap, &mut c, 4, USER, test_scenario::ctx(&mut s));
        test_scenario::return_to_sender(&s, cap);
        test_scenario::return_shared(c);
        test_scenario::next_tx(&mut s, USER);
        let op = test_scenario::take_from_sender<OperatorCap>(&s);
        let c = test_scenario::take_shared<GlobalConfig>(&s);
        config::check_rebalance_manager_role(&c, object::id_address(&op));
        test_scenario::return_to_sender(&s, op);
        test_scenario::return_shared(c);
        test_scenario::end(s);
    }

    #[test, expected_failure(abort_code = 3, location = turbos_assets_manage::config)]
    fun security_operator_owner_address_does_not_inherit_cap_role() {
        let (s, cap, c) = setup();
        router::add_operator(&cap, &mut c, 4, USER, test_scenario::ctx(&mut s));
        config::check_rebalance_manager_role(&c, USER);
        finish(s, cap, c);
    }

    #[test, expected_failure(abort_code = 3, location = turbos_assets_manage::config)]
    fun security_zeroed_operator_cap_cannot_rebalance() {
        let (s, cap, c) = setup();
        router::add_operator(&cap, &mut c, 4, ADMIN, test_scenario::ctx(&mut s));
        test_scenario::return_to_sender(&s, cap);
        test_scenario::return_shared(c);
        test_scenario::next_tx(&mut s, ADMIN);
        let op = test_scenario::take_from_sender<OperatorCap>(&s);
        let cap = test_scenario::take_from_sender<AdminCap>(&s);
        let c = test_scenario::take_shared<GlobalConfig>(&s);
        let id = object::id_address(&op);
        router::set_roles(&cap, &mut c, id, 0);
        config::check_rebalance_manager_role(&c, id);
        test_scenario::return_to_sender(&s, op);
        finish(s, cap, c);
    }
}
