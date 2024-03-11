// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::acl {
    use std::vector;
    use std::option::{Self, Option};
    use sui::linked_table::{Self, LinkedTable};
    use sui::tx_context::{Self, TxContext};

    const EWrongRoleValue: u64 = 0;

    struct ACL has store {
	    permissions: LinkedTable<address, u128>
    }
    struct Member has copy, drop, store {
        address: address,
        permission: u128
    }

    public fun new(ctx: &mut TxContext): ACL {
        ACL {
            permissions: linked_table::new<address, u128>(ctx)
        }
    }

    public fun has_role(acl: &ACL, addr: address, role: u8): bool {
        assert!(role < 128, EWrongRoleValue);
        if (!linked_table::contains<address, u128>(&acl.permissions, addr)) {
            false
        } else {
            let permission = *linked_table::borrow<address, u128>(&acl.permissions, addr);
            ((permission & (1 << role)) > 0)
        }
    }

    public fun set_roles(acl: &mut ACL, addr: address, roles: u128) {
        if (linked_table::contains<address, u128>(&acl.permissions, addr)) {
            *linked_table::borrow_mut<address, u128>(&mut acl.permissions, addr) = roles;
        } else {
            linked_table::push_back<address, u128>(&mut acl.permissions, addr, roles);
        }
    }

    public fun add_role(acl: &mut ACL, addr: address, role: u8) {
        assert!(role < 128, EWrongRoleValue);
        if (linked_table::contains<address, u128>(&acl.permissions, addr)) {
            let perm = linked_table::borrow_mut<address, u128>(&mut acl.permissions, addr);
            let mask = (1 << role);
            *perm = *perm | mask;
        } else {
            linked_table::push_back<address, u128>(&mut acl.permissions, addr, 1 << role);
        }
    }

    public fun remove_role(acl: &mut ACL, addr: address, role: u8) {
        assert!(role < 128, EWrongRoleValue);
        if (linked_table::contains<address, u128>(&acl.permissions, addr)) {
            let perm = linked_table::borrow_mut<address, u128>(&mut acl.permissions, addr);
            // like ~(1 << role)
            let mask = (1 << role) ^ 0xffffffffffffffffffffffffffffffff;
            *perm = *perm & mask;
        }
    }

    public fun remove_member(acl: &mut ACL, addr: address) {
        if (linked_table::contains<address, u128>(&acl.permissions, addr)) {
            linked_table::remove<address, u128>(&mut acl.permissions, addr);
        }
    }

    public fun get_members(acl: &ACL): vector<Member> {
        let members: vector<Member> = vector::empty();
        let current_opt = linked_table::front<address, u128>(&acl.permissions);
        while (option::is_some(current_opt)) {
            let current = option::borrow(current_opt);
            let permission = *linked_table::borrow<address, u128>(&acl.permissions, *current);
            vector::push_back(&mut members, Member { address: *current, permission });
            current_opt = linked_table::next<address, u128>(&acl.permissions, *current);
        };
        members
    }

    public fun get_permission(acl: &ACL, addr: address): u128 {
        if (!linked_table::contains<address, u128>(&acl.permissions, addr)) {
            0
        } else {
            *linked_table::borrow<address, u128>(&acl.permissions, addr)
        }
    }
}