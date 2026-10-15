// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

#[test_only]
module turbos_assets_manage::reward_tests {
    use std::string::{Self, String};
    use sui::test_utils::{assert_eq};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID, ID};
    use sui::test_scenario::{Self, Scenario};
    use turbos_clmm::btc::{BTC};
    use turbos_clmm::usdc::{USDC};
    use turbos_clmm::eth::{ETH};
    use turbos_clmm::sui::{SUI};
    use turbos_clmm::trb::{TRB};
    use turbos_clmm::fee3000bps::{FEE3000BPS};
    use turbos_clmm::pool::{Self, Pool, Versioned};
    use turbos_clmm::tools_tests;
    use turbos_clmm::position_manager::{Self, Positions};
    use turbos_clmm::i32::{Self};
    use turbos_clmm::math_tick;
    use turbos_clmm::fee::{Fee};
    use turbos_clmm::swap_router;
    use turbos_clmm::position_manager_tests;
    use turbos_clmm::pool_factory::{Self, PoolFactoryAdminCap, PoolConfig};
    use turbos_clmm::math_sqrt_price::{Self};
    use turbos_assets_manage::vault::{Self, Vault, Strategy};
    use turbos_assets_manage::config::{Self, AdminCap, GlobalConfig, OperatorCap};
    use turbos_assets_manage::router;
    use turbos_assets_manage::rewarder::{Self, RewarderManager};
    use sui::clock::{Self, Clock};
    use sui::transfer;

    const MAX_SQRT_PRICE_X64: u128 = 79226673515401279992447579055;
    const MIN_SQRT_PRICE_X64: u128 = 4295048016;
    const MAX_TICK_INDEX: u32 = 443636;

    fun prepare_tests(
        admin: address,
        player: address,
        player2: address, 
        scenario: &mut Scenario,
    ) {
        tools_tests::init_tests_coin(
            admin,
            player,
            player2,
            100000000000,
            scenario
        );

        tools_tests::init_pool_factory(
            admin,
            scenario
        );

        tools_tests::init_fee_type(
            admin,
            scenario
        );

        tools_tests::set_fee_protocol(
            admin,
            100000,
            scenario
        );

        tools_tests::init_clock(
            player,
            scenario
        );

        //init pool manager
        test_scenario::next_tx(scenario, admin);
        {
            position_manager_tests::init_pool_manager(admin, scenario);
        };

        //init BTCUSDC pool
        test_scenario::next_tx(scenario, admin);
        {
            let admin_cap = test_scenario::take_from_sender<PoolFactoryAdminCap>(scenario);
            let pool_config = test_scenario::take_shared<PoolConfig>(scenario);
            let fee_type = test_scenario::take_immutable<Fee<FEE3000BPS>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let versioned = test_scenario::take_shared<Versioned>(scenario);
            //price=1, 1btc = 1usdc
            let sqrt_price = math_tick::sqrt_price_from_tick_index(i32::from(0));
            //let sqrt_price = math_sqrt_price::encode_price_sqrt(1, 10);
            pool_factory::deploy_pool<BTC, USDC, FEE3000BPS>(
                &mut pool_config,
                &fee_type,
                sqrt_price,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(pool_config);
            test_scenario::return_immutable(fee_type);
            test_scenario::return_shared(versioned);
        };

        //add liquidity
        test_scenario::next_tx(scenario, player);
        {
            let clock = test_scenario::take_shared<Clock>(scenario);
            let versioned = test_scenario::take_shared<Versioned>(scenario);
            let pool = test_scenario::take_shared<Pool<BTC, USDC, FEE3000BPS>>(scenario);
            let positions = test_scenario::take_shared<Positions>(scenario);
            let btc = test_scenario::take_from_sender<Coin<BTC>>(scenario);
            let usdc = test_scenario::take_from_sender<Coin<USDC>>(scenario);
            let fee_type = test_scenario::take_immutable<Fee<FEE3000BPS>>(scenario);
            let min_tick_index = math_tick::get_min_tick(60);
            let max_tick_index = math_tick::get_max_tick(60);

            //btc
            position_manager::mint<BTC, USDC, FEE3000BPS>(
                &mut pool,
                &mut positions,
                tools_tests::coin_to_vec(btc),
                tools_tests::coin_to_vec(usdc),
                i32::abs_u32(min_tick_index),
                i32::is_neg(min_tick_index),
                i32::abs_u32(max_tick_index),
                i32::is_neg(max_tick_index),
                100000, //10 BTC
                100000, 
                0,
                0,
                player,
                1,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_immutable(fee_type);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(positions);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(versioned);
        };

        //init vault
        test_scenario::next_tx(scenario, admin);
        {
            vault::init_for_testing(test_scenario::ctx(scenario));
        };

        //init config
        test_scenario::next_tx(scenario, admin);
        {
            config::init_for_testing(test_scenario::ctx(scenario));
        };

        //init rewarder
        test_scenario::next_tx(scenario, admin);
        {
            rewarder::init_for_testing(test_scenario::ctx(scenario));
        };

        //init admin operator
        test_scenario::next_tx(scenario, admin);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let global_config = test_scenario::take_shared<GlobalConfig>(scenario);

            router::set_package_version(&admin_cap, &mut global_config, 4);
            router::add_operator(
                &admin_cap, 
                &mut global_config, 
                7,
                admin,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(global_config);
        };

        //init rebalance operator
        test_scenario::next_tx(scenario, admin);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let global_config = test_scenario::take_shared<GlobalConfig>(scenario);

            router::add_operator(
                &admin_cap, 
                &mut global_config, 
                7,
                player,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(global_config);
        };   
    }

    #[test]
    public fun test_reward() {
        let (admin, player, player2)  = (@0x0, @0x1, @0x2);
        let scenario_val = test_scenario::begin(admin);
        let scenario = &mut scenario_val;
        prepare_tests(admin, player, player2, scenario);

        test_scenario::next_tx(scenario, player);
        {
            let operator_cap = test_scenario::take_from_sender<OperatorCap>(scenario);
            let global_config = test_scenario::take_shared<GlobalConfig>(scenario);
            let rewarder_manager = test_scenario::take_shared<RewarderManager>(scenario);
            let clmm_pool = test_scenario::take_shared<Pool<BTC, USDC, FEE3000BPS>>(scenario);
            let clmm_positions = test_scenario::take_shared<Positions>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let versioned = test_scenario::take_shared<Versioned>(scenario);
            
            let btc = test_scenario::take_from_sender<Coin<BTC>>(scenario);
            let usdc = test_scenario::take_from_sender<Coin<USDC>>(scenario); 
            let eth = test_scenario::take_from_sender<Coin<ETH>>(scenario); 

            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            let tick_spacing = pool::get_pool_tick_spacing(&clmm_pool);
            let base_tick_step = 10;
            let limit_tick_step = 3;
            let (base_lower_index, base_upper_index) = vault::calculate_tick_index(current_tick_index, tick_spacing, base_tick_step);
            let (limit_lower_index, limit_upper_index) = vault::calculate_tick_index(current_tick_index, tick_spacing, limit_tick_step);

            //create rewarder
            rewarder::create_rewarder<ETH>(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                100,
                &clock,
                test_scenario::ctx(scenario),
            );

            //deposit rewarder 
            rewarder::deposit_rewarder<ETH>(
                &global_config,
                &mut rewarder_manager,
                coin::split(&mut eth, 10000, test_scenario::ctx(scenario)),
                test_scenario::ctx(scenario),
            );

            //strategy one
            let strategy_one = vault::create_strategy(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &clmm_pool,
                MAX_TICK_INDEX,
                true,
                MAX_TICK_INDEX,
                false,
                string::utf8(b"https://xx"),
                80, //80%
                50, //50%
                10,
                3,
                test_scenario::ctx(scenario),
            );

            //add to rewarder
            vault::add_rewarder<ETH>(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &mut strategy_one,
                50,
                &clock,
            );

            //strategy two
            let strategy_two = vault::create_strategy(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &clmm_pool,
                MAX_TICK_INDEX,
                true,
                MAX_TICK_INDEX,
                false,
                string::utf8(b"https://xx"),
                80, //80%
                50, //50%
                20,
                6,
                test_scenario::ctx(scenario),
            );

            //add to rewarder
            vault::add_rewarder<ETH>(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &mut strategy_two,
                50,
                &clock,
            );

            let strategy_one_vault_one = vault::open_vault(
                &global_config,
                &mut strategy_one,
                &clmm_pool,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                base_tick_step,
                limit_tick_step,
                test_scenario::ctx(scenario),
            );
            let strategy_one_vault_one_id = object::id(&strategy_one_vault_one);
            let share = vault::get_vault_share(&strategy_one, strategy_one_vault_one_id);

            let amount_a = 10000;
            let amount_b = 10000;
            vault::deposit(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_one,
                &mut strategy_one_vault_one,
                &mut clmm_pool,
                &mut clmm_positions,
                coin::split(&mut btc, amount_a, test_scenario::ctx(scenario)),
                coin::split(&mut usdc, amount_b, test_scenario::ctx(scenario)),
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            let (balance_a_amount, balance_b_amount) = vault::get_vault_total_amount<BTC, USDC, FEE3000BPS>(
                &strategy_one,
                &clmm_pool,
                strategy_one_vault_one_id,
            );
            assert_eq(balance_a_amount, 9999);
            assert_eq(balance_b_amount, 9999);
            let share = vault::get_vault_share(&strategy_one, strategy_one_vault_one_id);
            assert_eq(share, 19998);

            // // strategy one vault two
            let strategy_one_vault_two = vault::open_vault(
                &global_config,
                &mut strategy_one,
                &clmm_pool,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                base_tick_step,
                limit_tick_step,
                test_scenario::ctx(scenario),
            );
            let strategy_one_vault_two_id = object::id(&strategy_one_vault_two);

            let amount_a = 10000;
            let amount_b = 10000;
            vault::deposit(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_one,
                &mut strategy_one_vault_two,
                &mut clmm_pool,
                &mut clmm_positions,
                coin::split(&mut btc, amount_a, test_scenario::ctx(scenario)),
                coin::split(&mut usdc, amount_b, test_scenario::ctx(scenario)),
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            let (balance_a_amount, balance_b_amount) = vault::get_vault_total_amount<BTC, USDC, FEE3000BPS>(
                &strategy_one,
                &clmm_pool,
                strategy_one_vault_two_id,
            );
            assert_eq(balance_a_amount, 9999);
            assert_eq(balance_b_amount, 9999);
            let share = vault::get_vault_share(&strategy_one, strategy_one_vault_two_id);
            assert_eq(share, 19998);

            let strategy_one_total_share = vault::get_strategy_total_share(&strategy_one);
            assert_eq(strategy_one_total_share, 39996);

            // strategy two vault one
            let base_tick_step = 20;
            let limit_tick_step = 6;
            let (base_lower_index, base_upper_index) = vault::calculate_tick_index(current_tick_index, tick_spacing, base_tick_step);
            let (limit_lower_index, limit_upper_index) = vault::calculate_tick_index(current_tick_index, tick_spacing, limit_tick_step);
            let strategy_two_vault_one = vault::open_vault(
                &global_config,
                &mut strategy_two,
                &clmm_pool,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                base_tick_step,
                limit_tick_step,
                test_scenario::ctx(scenario),
            );
            let strategy_two_vault_one_id = object::id(&strategy_two_vault_one);

            let amount_a = 20000;
            let amount_b = 20000;
            vault::deposit(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_two,
                &mut strategy_two_vault_one,
                &mut clmm_pool,
                &mut clmm_positions,
                coin::split(&mut btc, amount_a, test_scenario::ctx(scenario)),
                coin::split(&mut usdc, amount_b, test_scenario::ctx(scenario)),
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            let (balance_a_amount, balance_b_amount) = vault::get_vault_total_amount<BTC, USDC, FEE3000BPS>(
                &strategy_two,
                &clmm_pool,
                strategy_two_vault_one_id,
            );
            assert_eq(balance_a_amount, 19999);
            assert_eq(balance_b_amount, 19999);

            let share = vault::get_vault_share(&strategy_two, strategy_two_vault_one_id);
            assert_eq(share, 39998);

            let strategy_two_total_share = vault::get_strategy_total_share(&strategy_two);
            assert_eq(strategy_two_total_share, 39998);

            //forward 10s to emissions
            clock::increment_for_testing(&mut clock, 10000); //10s
            let reward_one = vault::collect_reward<ETH>(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_one,
                &strategy_one_vault_one,
                &clock,
                test_scenario::ctx(scenario),
            );
            let amount = coin::value(&reward_one);
            assert_eq(amount, 249);
            coin::join(&mut eth, reward_one);

            let reward_two = vault::collect_reward<ETH>(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_one,
                &strategy_one_vault_two,
                &clock,
                test_scenario::ctx(scenario),
            );
            amount = coin::value(&reward_two);
            assert_eq(amount, 249);
            coin::join(&mut eth, reward_two);

            let reward_three = vault::collect_reward<ETH>(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_two,
                &strategy_two_vault_one,
                &clock,
                test_scenario::ctx(scenario),
            );
            amount = coin::value(&reward_three);
            assert_eq(amount, 499);
            coin::join(&mut eth, reward_three);

            clock::increment_for_testing(&mut clock, 20000); //20s
            let reward_one = vault::collect_reward<ETH>(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_one,
                &strategy_one_vault_one,
                &clock,
                test_scenario::ctx(scenario),
            );
            let amount = coin::value(&reward_one);
            assert_eq(amount, 500);
            coin::join(&mut eth, reward_one);

            let reward_three = vault::collect_reward<ETH>(
                &global_config,
                &mut rewarder_manager,
                &mut strategy_two,
                &strategy_two_vault_one,
                &clock,
                test_scenario::ctx(scenario),
            );
            amount = coin::value(&reward_three);
            assert_eq(amount, 1000);
            coin::join(&mut eth, reward_three);

            transfer::public_share_object(strategy_one);
            transfer::public_share_object(strategy_two);
            transfer::public_transfer(strategy_one_vault_one, player);
            transfer::public_transfer(strategy_one_vault_two, player);
            transfer::public_transfer(strategy_two_vault_one, player);
            test_scenario::return_to_sender(scenario, btc);
            test_scenario::return_to_sender(scenario, usdc);
            test_scenario::return_to_sender(scenario, eth);
            test_scenario::return_shared(global_config);
            test_scenario::return_to_sender(scenario, operator_cap);
            test_scenario::return_shared(clmm_pool);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(versioned);
            test_scenario::return_shared(rewarder_manager);
            test_scenario::return_shared(clmm_positions);
        };

        test_scenario::end(scenario_val);
    }
}
