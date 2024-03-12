// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::rewarder {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use std::type_name::{Self, TypeName};
    use sui::table::{Self, Table};
    use sui::linked_table::{Self, LinkedTable};
    use sui::bag::{Self, Bag};
    use sui::event;
    use turbos_assets_manage::config::{Self, GlobalConfig, OperatorCap};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use std::option::{Self, Option};

    struct StrategyRewarderInfo has store {
	    allocate_point: u64,
	    acc_per_share: u128,
	    last_reward_time: u64,
	    reward_released: u128,
	    reward_harvested: u64
    }
    
    struct Rewarder has store {
	    reward_coin: TypeName,
	    total_allocate_point: u64,
	    emission_per_second: u128,
	    last_reward_time: u64,
	    total_reward_released: u128,
	    total_reward_harvested: u64,
	    strategys: LinkedTable<ID, StrategyRewarderInfo>
    }
    
    struct RewarderManager has store, key {
	    id: UID,
	    vault: Bag,
	    strategy_shares: LinkedTable<ID, u128>,
	    rewarders: LinkedTable<TypeName, Rewarder>
    }

    struct InitRewarderManagerEvent has copy, drop {
	    id: ID
    }

    struct CreateRewarderEvent has copy, drop {
        reward_coin: TypeName,
        emission_per_second: u128
    }

    struct UpdateRewarderEvent has copy, drop {
        reward_coin: TypeName,
        emission_per_second: u128
    }

    struct DepositEvent has copy, drop {
        reward_type: TypeName,
        deposit_amount: u64,
        after_amount: u64
    }

    fun init(ctx: &mut TxContext) {
        let uid = object::new(ctx);
        let vault = bag::new(ctx);
        let strategy_shares = linked_table::new<ID, u128>(ctx);
        let rewarders = linked_table::new<TypeName, Rewarder>(ctx);

        let rewarder_manager = RewarderManager {
            id: uid,
            vault: vault,
            strategy_shares: strategy_shares,
            rewarders: rewarders,
        };

        let id = object::id(&rewarder_manager);

        transfer::share_object(rewarder_manager);

        let event = InitRewarderManagerEvent { id: id };
        event::emit(event);
    }

    public fun deposit_rewarder<T>(config: &GlobalConfig, manager: &mut RewarderManager, balance: Balance<T>) {
        config::checked_package_version(config);

        let type_name = type_name::get<T>();
        if (!bag::contains<TypeName>(&manager.vault, type_name)) {
            let zero_balance = balance::zero<T>();
            bag::add<TypeName, Balance<T>>(&mut manager.vault, type_name, zero_balance);
        };

        let before_amount = balance::value<T>(&balance);
        let after_amount = balance::join<T>(bag::borrow_mut<TypeName, Balance<T>>(&mut manager.vault, type_name), balance);

        let deposit_event = DepositEvent {
            reward_type: type_name,
            deposit_amount: before_amount,
            after_amount: after_amount,
        };
        event::emit(deposit_event);
    }

    public fun create_rewarder<T: copy + drop + store>(
        operator_cap: &OperatorCap, 
        config: &GlobalConfig, 
        manager: &mut RewarderManager, 
        emission_per_second: u128, 
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        config::checked_package_version(config);

        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_reward_manager_role(config, operator_address);

        let type_name = type_name::get<T>();

        let current_time = clock::timestamp_ms(clock) / 1000;

        let strategys = linked_table::new<ID, StrategyRewarderInfo>(ctx);

        let rewarder = Rewarder {
            reward_coin: type_name,
            total_allocate_point: 0,
            emission_per_second: emission_per_second,
            last_reward_time: current_time,
            total_reward_released: 0,
            total_reward_harvested: 0,
            strategys: strategys,
        };

        assert!(!linked_table::contains<TypeName, Rewarder>(&manager.rewarders, type_name), 1);

        linked_table::push_back<TypeName, Rewarder>(&mut manager.rewarders, type_name, rewarder);

        let create_event = CreateRewarderEvent {
            reward_coin: type_name,
            emission_per_second: emission_per_second,
        };
        event::emit(create_event);
    }

    public fun update_rewarder<T: copy + drop + store>(
        operator_cap: &OperatorCap, 
        config: &GlobalConfig, 
        manager: &mut RewarderManager, 
        new_emission_per_second: u128, 
        clock: &Clock
    ) {
        config::checked_package_version(config);

        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_reward_manager_role(config, operator_address);

        let type_name = type_name::get<T>();

        assert!(linked_table::contains<TypeName, Rewarder>(&manager.rewarders, type_name), 2);

        let current_time = clock::timestamp_ms(clock) / 1000;

        accumulate_strategys_reward<T>(manager, current_time);

        let rewarder = linked_table::borrow_mut<TypeName, Rewarder>(&mut manager.rewarders, type_name);
    
        accumulate_rewarder_released(rewarder , current_time);
        rewarder.emission_per_second = new_emission_per_second;

        let update_event = UpdateRewarderEvent {
            reward_coin: type_name,
            emission_per_second: new_emission_per_second,
        };
        event::emit(update_event);
    }

    public fun accumulate_rewarder_released(rewarder: &mut Rewarder, current_time: u64) {
        if (rewarder.last_reward_time <= current_time) {
            let elapsed_time = current_time - rewarder.last_reward_time;
            if (rewarder.emission_per_second > 0) {
                let additional_rewards = rewarder.emission_per_second * (elapsed_time as u128);
                rewarder.total_reward_released = rewarder.total_reward_released + additional_rewards;
            };
            rewarder.last_reward_time = current_time;
        }
    }

    public fun accumulate_strategys_reward<T>(manager: &mut RewarderManager, current_time: u64) {
        // Obtain a mutable reference to the specific rewarder by its type.
        let type_name = type_name::get<T>();
        let rewarder = linked_table::borrow_mut<TypeName, Rewarder>(&mut manager.rewarders, type_name);

        if (rewarder.emission_per_second == 0) {
            return;
        };

        let current_opt = linked_table::front<ID, StrategyRewarderInfo>(&rewarder.strategys);
        while (option::is_some(current_opt)) {
            let strategy_id = *option::borrow(current_opt);
            let strategy_share = *linked_table::borrow<ID, u128>(&manager.strategy_shares, strategy_id);
            accumulate_strategy_reward(rewarder, strategy_id, strategy_share, current_time);
            current_opt = linked_table::next<ID, StrategyRewarderInfo>(&rewarder.strategys, strategy_id);
        };

        rewarder.last_reward_time = current_time;
    }

    public fun accumulate_strategy_reward(
        rewarder: &mut Rewarder, 
        strategy_id: ID, 
        strategy_share: u128, 
        current_time: u64
    ): u128 {
        let strategy_info = linked_table::borrow_mut<ID, StrategyRewarderInfo>(&mut rewarder.strategys, strategy_id);

        if (current_time > strategy_info.last_reward_time && rewarder.emission_per_second > 0) {
            let elapsed_time = current_time - strategy_info.last_reward_time;

            let new_rewards = rewarder.emission_per_second * (elapsed_time as u128);

            let reward_per_share = new_rewards * strategy_share / (rewarder.total_allocate_point as u128);

            strategy_info.acc_per_share = strategy_info.acc_per_share + reward_per_share;

            strategy_info.last_reward_time = current_time;

            rewarder.total_reward_released = rewarder.total_reward_released + new_rewards;

        };

        strategy_info.acc_per_share
    }


    public(friend) fun register_strategy(manager: &mut RewarderManager, strategy_id: ID) {
        if (!is_strategy_registered(manager, strategy_id)) {
            linked_table::push_back<ID, u128>(&mut manager.strategy_shares, strategy_id, 0);
        } else {
            abort 7;
        }
    }

    public fun is_strategy_registered(manager: &RewarderManager, strategy_id: ID): bool {
        linked_table::contains<ID, u128>(&manager.strategy_shares, strategy_id)
    }


    public(friend) fun add_strategy<T: store>(
        manager: &mut RewarderManager, 
        strategy_id: ID, 
        allocate_points: u64, 
        clock: &Clock
    ) {
        assert!(is_strategy_registered(manager, strategy_id), 6);

        let type_name = type_name::get<T>();
        assert!(!is_strategy_in_rewarder(manager, type_name, strategy_id), 3);

        let current_time = clock::timestamp_ms(clock) / 1000;

        accumulate_strategys_reward<T>(manager, current_time);

        let rewarder = linked_table::borrow_mut<TypeName, Rewarder>(&mut manager.rewarders, type_name);

        accumulate_rewarder_released(rewarder, current_time);

        let strategy_info = StrategyRewarderInfo {
            allocate_point: allocate_points,
            acc_per_share: 0,
            last_reward_time: current_time,
            reward_released: 0,
            reward_harvested: 0,
        };
        linked_table::push_back<ID, StrategyRewarderInfo>(&mut rewarder.strategys, strategy_id, strategy_info);

        rewarder.total_allocate_point = rewarder.total_allocate_point + allocate_points;
    }

    public fun is_strategy_in_rewarder(manager: &RewarderManager, type_name: TypeName, strategy_id: ID): bool {
        let rewarder = linked_table::borrow<TypeName, Rewarder>(&manager.rewarders, type_name);
        linked_table::contains<ID, StrategyRewarderInfo>(&rewarder.strategys, strategy_id)
    }
}