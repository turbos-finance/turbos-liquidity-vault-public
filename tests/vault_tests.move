// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

#[test_only]
module turbos_assets_manage::vault_tests {
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
    use sui::clock::{Clock};
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
            1000000000,
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
            let sqrt_price = math_sqrt_price::encode_price_sqrt(1, 1);
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
                10000000,
                10000000,
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

        //init BTCUSDC strategy
        test_scenario::next_tx(scenario, admin);
        {
            let operator_cap = test_scenario::take_from_sender<OperatorCap>(scenario);
            let global_config = test_scenario::take_shared<GlobalConfig>(scenario);
            let rewarder_manager = test_scenario::take_shared<RewarderManager>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let versioned = test_scenario::take_shared<Versioned>(scenario);
            let clmm_pool = test_scenario::take_shared<Pool<BTC, USDC, FEE3000BPS>>(scenario);

            router::create_strategy(
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
                80, //80%
                10,
                3,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_to_sender(scenario, operator_cap);
            test_scenario::return_shared(global_config);
            test_scenario::return_shared(rewarder_manager);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(clmm_pool);
            test_scenario::return_shared(versioned);
        };
    }

    #[test]
    public fun test_vault_base() {
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
            let strategy = test_scenario::take_shared<Strategy>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let versioned = test_scenario::take_shared<Versioned>(scenario);
            
            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            let tick_spacing = pool::get_pool_tick_spacing(&clmm_pool);
            let base_tick_step = 10;
            let limit_tick_step = 3;
            let (base_lower_index, base_upper_index) = vault::calculate_tick_index(current_tick_index, tick_spacing, base_tick_step);
            let (limit_lower_index, limit_upper_index) = vault::calculate_tick_index(current_tick_index, tick_spacing, limit_tick_step);

            let vault = vault::open_vault(
                &global_config,
                &mut strategy,
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

            let vault_id = object::id(&vault);
            let btc = test_scenario::take_from_sender<Coin<BTC>>(scenario);
            let usdc = test_scenario::take_from_sender<Coin<USDC>>(scenario); 

            let amount_a = 100000000;
            let amount_b = 100000000;
            vault::deposit(
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                &mut vault,
                &mut clmm_pool,
                &mut clmm_positions,
                coin::split(&mut btc, amount_a, test_scenario::ctx(scenario)),
                coin::split(&mut usdc, amount_b, test_scenario::ctx(scenario)),
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            let (balance_a_amount, balance_b_amount) = vault::get_vault_total_amount<BTC, USDC, FEE3000BPS>(
                &strategy,
                &clmm_pool,
                object::id(&vault),
            );
            assert_eq(balance_a_amount, 99999999);
            assert_eq(balance_b_amount, 99999999);

            //increase
            vault::deposit(
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                &mut vault,
                &mut clmm_pool,
                &mut clmm_positions,
                coin::split(&mut btc, amount_a, test_scenario::ctx(scenario)),
                coin::split(&mut usdc, amount_b, test_scenario::ctx(scenario)),
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            (balance_a_amount, balance_b_amount) = vault::get_vault_total_amount<BTC, USDC, FEE3000BPS>(
                &strategy,
                &clmm_pool,
                object::id(&vault),
            );
            assert_eq(balance_a_amount, 199999999);
            assert_eq(balance_b_amount, 199999999);

            //withdraw 50%
            let (coin_a, coin_b) = vault::withdraw(
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                &mut vault,
                &mut clmm_pool,
                &mut clmm_positions,
                 50,
                 false,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            (balance_a_amount, balance_b_amount) = vault::get_vault_total_amount<BTC, USDC, FEE3000BPS>(
                &strategy,
                &clmm_pool,
                vault_id,
            );
            assert_eq(balance_a_amount, 99999999);
            assert_eq(balance_b_amount, 99999999);
            assert_eq(coin::value(&coin_a), 99999999);
            assert_eq(coin::value(&coin_b), 99999999);
            coin::join(&mut btc, coin_a);
            coin::join(&mut usdc, coin_b);

            //check can rebalance
            let check_rebalance = vault::check_rebalance(
                &global_config,
                &mut strategy,
                vault_id,
                &mut clmm_pool,
                test_scenario::ctx(scenario),
            );
            let (rebalance,_,_,_,_,_) = vault::get_check_rebalance_info(&check_rebalance);
            assert_eq(rebalance, false);

            //current tick index is 0, need move 9 * 60 ticks to trigger rebalance
            swap_router::swap_b_a(
                &mut clmm_pool,
                tools_tests::coin_to_vec(coin::split(&mut usdc, 70000000, test_scenario::ctx(scenario))),
                70000000, //amount_in 
                1, //amount_threshold
                MAX_SQRT_PRICE_X64 - 1,
                true,
                player,
                1,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            assert_eq(i32::as_u32(current_tick_index), 446);

            //index from 0 to 446, no trigger
            //check can rebalance
            let check_rebalance = vault::check_rebalance(
                &global_config,
                &mut strategy,
                vault_id,
                &mut clmm_pool,
                test_scenario::ctx(scenario),
            );
            let (rebalance,base_lower_index,base_upper_index, base_just_increase,limit_lower_index,limit_upper_index) = vault::get_check_rebalance_info(&check_rebalance);
            assert_eq(rebalance, false);

            swap_router::swap_b_a(
                &mut clmm_pool,
                tools_tests::coin_to_vec(coin::split(&mut usdc, 10000000, test_scenario::ctx(scenario))),
                10000000, //amount_in 
                1, //amount_threshold
                MAX_SQRT_PRICE_X64 - 1,
                true,
                player,
                1,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            assert_eq(i32::as_u32(current_tick_index), 509);

            //index from 0 to 509, trigger, threshold: 600 * 0.8 = 480
            let check_rebalance = vault::check_rebalance(
                &global_config,
                &mut strategy,
                vault_id,
                &mut clmm_pool,
                test_scenario::ctx(scenario),
            );
            let (rebalance,base_lower_index,base_upper_index, base_just_increase,limit_lower_index,limit_upper_index) = vault::get_check_rebalance_info(&check_rebalance);
            assert_eq(rebalance, true);

            //rebalance
            vault::rebalance(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                vault_id,
                rebalance,
                base_just_increase,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                &mut clmm_pool,
                &mut clmm_positions,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            assert_eq(vault::get_vault_base_last_tick_index(&strategy, vault_id), i32::from(509));
            assert_eq(vault::get_vault_limit_last_tick_index(&strategy, vault_id), i32::from(509));
            assert_eq(vault::get_vault_base_lower_index(&strategy, vault_id), i32::neg_from(180));
            assert_eq(vault::get_vault_base_upper_index(&strategy, vault_id), i32::from(1140));
            // ask order
            assert_eq(vault::get_vault_limit_lower_index(&strategy, vault_id), i32::from(240));
            assert_eq(vault::get_vault_limit_upper_index(&strategy, vault_id), i32::from(480));

            //Continue forward 3 tick_spacing to trigger limit rebalance
            swap_router::swap_b_a(
                &mut clmm_pool,
                tools_tests::coin_to_vec(coin::split(&mut usdc, 10000000, test_scenario::ctx(scenario))),
                6000000, //amount_in 
                1, //amount_threshold
                MAX_SQRT_PRICE_X64 - 1,
                true,
                player,
                1,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            assert_eq(i32::as_u32(current_tick_index), 663);

            //index from 509 to 663, trigger, threshold: 180 * 0.8 = 144
            let check_rebalance = vault::check_rebalance(
                &global_config,
                &mut strategy,
                vault_id,
                &mut clmm_pool,
                test_scenario::ctx(scenario),
            );
            let (rebalance,base_lower_index,base_upper_index, base_just_increase,limit_lower_index,limit_upper_index) = vault::get_check_rebalance_info(&check_rebalance);            //base tick range not change
            assert_eq(base_lower_index, i32::neg_from(180));
            assert_eq(base_upper_index, i32::from(1140));
            assert_eq(limit_lower_index, i32::from(420));
            assert_eq(limit_upper_index, i32::from(900));
            assert_eq(rebalance, true);
            assert_eq(base_just_increase, true);

            //rebalance
            vault::rebalance(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                vault_id,
                rebalance,
                base_just_increase,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                &mut clmm_pool,
                &mut clmm_positions,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            assert_eq(vault::get_vault_base_last_tick_index(&strategy, vault_id), i32::from(509));
            assert_eq(vault::get_vault_limit_last_tick_index(&strategy, vault_id), i32::from(663));
            assert_eq(vault::get_vault_base_lower_index(&strategy, vault_id), i32::neg_from(180));
            assert_eq(vault::get_vault_base_upper_index(&strategy, vault_id), i32::from(1140));
            assert_eq(vault::get_vault_limit_lower_index(&strategy, vault_id), i32::from(420));
            assert_eq(vault::get_vault_limit_upper_index(&strategy, vault_id), i32::from(660));


            //Continue forward 10 tick_spacing to trigger base rebalance, and exceeding upper limit of base
            swap_router::swap_b_a(
                &mut clmm_pool,
                tools_tests::coin_to_vec(coin::split(&mut usdc, 20000000, test_scenario::ctx(scenario))),
                20000000, //amount_in 
                1, //amount_threshold
                MAX_SQRT_PRICE_X64 - 1,
                true,
                player,
                1,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            assert_eq(i32::as_u32(current_tick_index), 3221);

            //index from 663 to 3221, trigger
            let check_rebalance = vault::check_rebalance(
                &global_config,
                &mut strategy,
                vault_id,
                &mut clmm_pool,
                test_scenario::ctx(scenario),
            );
            let (rebalance,base_lower_index,base_upper_index, base_just_increase,limit_lower_index,limit_upper_index) = vault::get_check_rebalance_info(&check_rebalance);            //base tick range not change
            //base tick range not change
            assert_eq(base_lower_index, i32::from(2520));
            assert_eq(base_upper_index, i32::from(3840));
            assert_eq(limit_lower_index, i32::from(2940));
            assert_eq(limit_upper_index, i32::from(3420));
            assert_eq(rebalance, true);
            assert_eq(base_just_increase, false);

            vault::rebalance(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                vault_id,
                rebalance,
                base_just_increase,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                &mut clmm_pool,
                &mut clmm_positions,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),

            );

            assert_eq(vault::get_vault_base_last_tick_index(&strategy, vault_id), i32::from(3221));
            assert_eq(vault::get_vault_limit_last_tick_index(&strategy, vault_id), i32::from(3221));
            assert_eq(vault::get_vault_base_lower_index(&strategy, vault_id), i32::from(2520));
            assert_eq(vault::get_vault_base_upper_index(&strategy, vault_id), i32::from(3840));
            assert_eq(vault::get_vault_limit_lower_index(&strategy, vault_id), i32::from(2940));
            assert_eq(vault::get_vault_limit_upper_index(&strategy, vault_id), i32::from(3180));

            //update update_vault_limit_rebalance_threshold to 50%
            router::update_vault_limit_rebalance_threshold(
                &operator_cap,
                &global_config,
                &mut strategy,
                vault_id,
                50,
            );

            //forward index from 3221 to 3124, trigger limit rebalance
            swap_router::swap_a_b(
                &mut clmm_pool,
                tools_tests::coin_to_vec(coin::split(&mut btc, 35000000, test_scenario::ctx(scenario))),
                35000000, //amount_in 
                1, //amount_threshold
                MIN_SQRT_PRICE_X64 + 1,
                true,
                player,
                1,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            let current_tick_index = pool::get_pool_current_index(&clmm_pool);
            assert_eq(i32::as_u32(current_tick_index), 3124);

            let check_rebalance = vault::check_rebalance(
                &global_config,
                &mut strategy,
                vault_id,
                &mut clmm_pool,
                test_scenario::ctx(scenario),
            );
            let (rebalance,base_lower_index,base_upper_index, base_just_increase,limit_lower_index,limit_upper_index) = vault::get_check_rebalance_info(&check_rebalance);
            assert_eq(base_lower_index, i32::from(2460));
            assert_eq(base_upper_index, i32::from(3780));
            assert_eq(limit_lower_index, i32::from(2880));
            assert_eq(limit_upper_index, i32::from(3360));
            assert_eq(rebalance, true);
            assert_eq(base_just_increase, false);

            vault::rebalance(
                &operator_cap,
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                vault_id,
                rebalance,
                base_just_increase,
                i32::abs_u32(base_lower_index),
                i32::is_neg(base_lower_index),
                i32::abs_u32(base_upper_index),
                i32::is_neg(base_upper_index),
                i32::abs_u32(limit_lower_index),
                i32::is_neg(limit_lower_index),
                i32::abs_u32(limit_upper_index),
                i32::is_neg(limit_upper_index),
                &mut clmm_pool,
                &mut clmm_positions,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),

            );

            // let vault_info = vault::borrow_vault_info(&strategy, vault_id);
            // std::debug::print(vault_info);

            assert_eq(vault::get_vault_base_last_tick_index(&strategy, vault_id), i32::from(3124));
            assert_eq(vault::get_vault_limit_last_tick_index(&strategy, vault_id), i32::from(3124));
            assert_eq(vault::get_vault_base_lower_index(&strategy, vault_id), i32::from(2460));
            assert_eq(vault::get_vault_base_upper_index(&strategy, vault_id), i32::from(3780));
            assert_eq(vault::get_vault_limit_lower_index(&strategy, vault_id), i32::from(2880));
            assert_eq(vault::get_vault_limit_upper_index(&strategy, vault_id), i32::from(3120));

            //increase
            vault::deposit(
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                &mut vault,
                &mut clmm_pool,
                &mut clmm_positions,
                coin::split(&mut btc, 100000, test_scenario::ctx(scenario)),
                coin::split(&mut usdc, 100000, test_scenario::ctx(scenario)),
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );

            //withdraw all
            let (coin_a, coin_b) = vault::withdraw(
                &global_config,
                &mut rewarder_manager,
                &mut strategy,
                &mut vault,
                &mut clmm_pool,
                &mut clmm_positions,
                100,
                true,
                &clock,
                &versioned,
                test_scenario::ctx(scenario),
            );
            coin::join(&mut btc, coin_a);
            coin::join(&mut usdc, coin_b);

            //close vault
            vault::close_vault<BTC, USDC>(
                &global_config,
                &mut strategy,
                vault,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_to_sender(scenario, btc);
            test_scenario::return_to_sender(scenario, usdc);
            test_scenario::return_shared(global_config);
            test_scenario::return_to_sender(scenario, operator_cap);
            test_scenario::return_shared(clmm_pool);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(versioned);
            test_scenario::return_shared(strategy);
            test_scenario::return_shared(rewarder_manager);
            test_scenario::return_shared(clmm_positions);
        };

        test_scenario::end(scenario_val);
    }
}