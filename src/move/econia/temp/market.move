/// Market-side functionality. See test-only constants for end-to-end
/// market order fill testing mock order sizes/prices: in the case of
/// both bids and asks, `USER_1` has the order closest to the spread,
/// while `USER_3` has the order furthest from the spread. `USER_0` then
/// places a market order against the book.
module econia::market {

    // Structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[method(
        book_orders_sdk,
        book_price_levels_sdk,
        get_orders_sdk,
        simulate_swap_sdk
    )]
    /// An order book for the given market
    struct OrderBook<phantom B, phantom Q, phantom E> has key {
        /// Number of base units in a base parcel
        scale_factor: u64,
        /// Asks tree
        asks: CritBitTree<Order>,
        /// Bids tree
        bids: CritBitTree<Order>,
        /// Order ID of minimum ask, per price-time priority. The ask
        /// side "spread maker".
        min_ask: u128,
        /// Order ID of maximum bid, per price-time priority. The bid
        /// side "spread maker".
        max_bid: u128,
        /// Serial counter for number of limit orders placed on book
        counter: u64
    }

    // Structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Fill a market order on behalf of a user. Invoked by a custodian,
    /// who passes an immutable reference to their
    /// `registry::CustodianCapability`. See wrapped call
    /// `fill_market_order_from_market_account()`.
    public fun fill_market_order_custodian<B, Q, E>(
        user: address,
        host: address,
        style: bool,
        max_base_parcels: u64,
        max_quote_units: u64,
        custodian_capability_ref: &registry::CustodianCapability
    ) acquires EconiaCapabilityStore, OrderBook {
        // Get custodian ID encoded in capability
        let custodian_id = registry::custodian_id(custodian_capability_ref);
        // Fill the market order, using custodian ID
        fill_market_order_from_market_account<B, Q, E>(
            user, host, custodian_id, style, max_base_parcels,
            max_quote_units);
    }

    /// For given market and `host`, execute specified `style` of swap,
    /// either `BUY` or `SELL`.
    ///
    /// # If a swap buy:
    /// * Quote coins at `quote_coins_ref_mut` are traded against the
    ///   order book until either there are no more trades on the book
    ///   or max possible quote coins have been spent on base coins
    /// * Purchased base coins are deposited to `base_coin_ref_mut`
    /// * `base_coins_ref_mut` does not need to have coins before swap,
    ///   but `quote_coins_ref_mut` does (amount of quote coins to
    ///   spend)
    ///
    /// # If a swap sell:
    /// * Base coins at `base_coins_ref_mut` are traded against the
    ///   order book until either there are no more trades on the book
    ///   or max possible base coins have been sold in exchange for
    ///   quote coins
    /// * Received quote coins are deposited to `quote_coins_ref_mut`
    /// * `quote_coins_ref_mut` does not need to have coins before swap,
    ///   but `base_coins_ref_mut` does (amount of base coins to sell)
    public fun swap<B, Q, E>(
        style: bool,
        host: address,
        base_coins_ref_mut: &mut coin::Coin<B>,
        quote_coins_ref_mut: &mut coin::Coin<Q>
    ) acquires EconiaCapabilityStore, OrderBook {
        // Assert host has an order book
        assert!(exists<OrderBook<B, Q, E>>(host), E_NO_ORDER_BOOK);
        // Borrow mutable reference to order book
        let order_book_ref_mut = borrow_global_mut<OrderBook<B, Q, E>>(host);
        // Get scale factor for book
        let scale_factor = order_book_ref_mut.scale_factor;
        // Get an Econia capability
        let econia_capability = get_econia_capability();
        // Compute max number of base coin parcels/quote coin units to
        // fill, based on side
        let (max_base_parcels, max_quote_units) = if (style == BUY)
            // If market buy, limiting factor is quote coins, so set
            // max base parcels to biggest value that can fit in u64
            (HI_64, coin::value(quote_coins_ref_mut)) else
            // If a market sell, max base parcels that can be filled is
            // number of base coins divided by scale factor (truncating
            // division) and quote coin argument has no impact on
            // matching engine
            (coin::value(base_coins_ref_mut) / scale_factor, 0);
        // Fill market order against the book
        fill_market_order<B, Q, E>(order_book_ref_mut, scale_factor, style,
            max_base_parcels, max_quote_units, base_coins_ref_mut,
            quote_coins_ref_mut, &econia_capability);
    }

    // Public functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public entry functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[cmd]
    /// Fill a market order. Invoked by a signing user. See wrapped
    /// call `fill_market_order_from_market_account()`.
    public entry fun fill_market_order_user<B, Q, E>(
        user: &signer,
        host: address,
        style: bool,
        max_base_parcels: u64,
        max_quote_units: u64,
    ) acquires EconiaCapabilityStore, OrderBook {
        // Fill the market order, with no custodian flag
        fill_market_order_from_market_account<B, Q, E>(
            address_of(user), host, NO_CUSTODIAN, style, max_base_parcels,
            max_quote_units);
    }

    // Public entry functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Private functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// For an `OrderBook` accessed by `order_book_ref_mut`, fill a
    /// market order for given `style` and `max_base_parcels`,
    /// optionally accounting for `max_quote_units` if `style` is `BUY`.
    ///
    /// Prepares a crit-bit tree for iterated traversal, then loops over
    /// nodes until the order is filled or another break condition is
    /// met. During iterated traversal, the "incoming user" (who places
    /// the market order or who has the order placed on their behalf by
    /// a custodian) has their order filled against the "target user"
    /// who has a "target position" on the order book.
    ///
    /// # Parameters
    /// * `order_book_ref_mut`: Mutable reference to order book to fill
    ///   against
    /// * `scale_factor`: Scale factor for corresponding `OrderBook`
    /// * `style`: `BUY` or `SELL`
    /// * `max_base_parcels`: The maximum number of base parcels to fill
    /// * `max_quote_units`: The maximum number of quote units to
    ///   exchange during a `BUY`, which may become a limiting factor
    ///   if the incoming user cannot afford to buy `max_base_parcels`
    ///   at market prices.
    /// * `base_coins_ref_mut`: Mutable reference to incoming user's
    ///   base coins, essentially a container to route to/from
    /// * `quote_coins_ref_mut`: Mutable reference to incoming user's
    ///   quote coins, essentially a container to route to/from
    /// * `econia_capability_ref`: Immutable reference to an
    ///   `EconiaCapability`
    ///
    /// # Assumes
    /// * Caller has provided sufficient collateral in `Coin` at
    ///   `quote_coins_ref_mut` if `style` is `BUY`, or to
    ///   `base_coins_ref_mut` if `style` is `SELL`
    /// * Caller has derived `scale_factor` from `OrderBook` accessed by
    ///   `order_book_ref_mut`
    fun fill_market_order<B, Q, E>(
        order_book_ref_mut: &mut OrderBook<B, Q, E>,
        scale_factor: u64,
        style: bool,
        max_base_parcels: u64,
        max_quote_units: u64,
        base_coins_ref_mut: &mut coin::Coin<B>,
        quote_coins_ref_mut: &mut coin::Coin<Q>,
        econia_capability_ref: &EconiaCapability
    ) {
        if (max_base_parcels == 0 || style == BUY && max_quote_units == 0)
            return; // Return if nothing to fill
        // Initialize local variables, get user's base/quote collateral
        let (base_parcels_to_fill, side, tree_ref_mut, spread_maker_ref_mut,
             n_orders, traversal_direction) = fill_market_order_init<B, Q, E>(
                order_book_ref_mut, style, max_base_parcels);
        if (n_orders != 0) { // If orders tree has orders to fill
            // Fill them in an iterated loop traversal
            fill_market_order_traverse_loop<B, Q, E>(style, side, scale_factor,
                tree_ref_mut, traversal_direction, n_orders,
                spread_maker_ref_mut, base_parcels_to_fill, base_coins_ref_mut,
                quote_coins_ref_mut, econia_capability_ref);
        };
    }

    /// Clean up before breaking during iterated market order filling.
    ///
    /// Inner function for `fill_market_order_traverse_loop()`.
    ///
    /// # Parameters
    /// * `null_order`: A null order used for mutable reference passing
    /// * `spread_maker_ref_mut`: Mutable reference to the spread maker
    ///   for order tree just filled against
    /// * `new_spread_maker`: New spread maker value to assign
    /// * `should_pop`: If ended traversal by completely filling against
    ///   the last order on the book
    /// * `tree_ref_mut`: Mutable reference to orders tree filled
    ///   against
    /// * `target_order_id`: If `should_pop` is `true`, the order ID of
    ///   the final order in the book that should be popped
    fun fill_market_order_break_cleanup(
        null_order: Order,
        spread_maker_ref_mut: &mut u128,
        new_spread_maker: u128,
        should_pop: bool,
        tree_ref_mut: &mut CritBitTree<Order>,
        target_order_id: u128
    ) {
        // Unpack null order
        Order{custodian_id: _, user: _, base_parcels: _} = null_order;
        // Update spread maker field
        *spread_maker_ref_mut = new_spread_maker;
        // If pop flagged, pop and unpack final order on tree
        if (should_pop) Order{base_parcels: _, user: _, custodian_id: _} =
            critbit::pop(tree_ref_mut, target_order_id);
    }

    /// If `style` is `BUY`, check indicated amount of base parcels
    /// to buy, updating as needed.
    ///
    /// Inner function for `fill_market_order_process_loop_order()`. In
    /// the case of a `BUY`, if the "target order" on the book (against
    /// which the "incoming user's" order fills against) has a high
    /// enough price, then the incoming user may not be able to afford
    /// as many base parcels as otherwise indicated by
    /// `base_parcels_to_fill_ref_mut`. If this is the case, the counter
    /// is updated with the amount the incoming can afford.
    ///
    /// # Parameters
    /// * `style`: `BUY` or `SELL`
    /// * `target_price`: Target order price
    /// * `quote_coins_ref`: Immutable reference to incoming user's
    ///    quote coins
    /// * `target_order_ref_mut`: Mutable reference to target order
    /// * `base_parcels_to_fill_ref_mut`: Mutable reference to counter
    ///   for number of base parcels still left to fill
    fun fill_market_order_check_base_parcels_to_fill<Q>(
        style: bool,
        target_price: u64,
        quote_coins_ref: &coin::Coin<Q>,
        target_order_ref_mut: &mut Order,
        base_parcels_to_fill_ref_mut: &mut u64
    ) {
        if (style == SELL) return; // No need to check when market sell
        // Calculate max base parcels that incoming user could buy at
        // target order price
        let base_parcels_can_afford = coin::value(quote_coins_ref) /
            target_price;
        // If user cannot afford to buy all base parcels in target order
        if (base_parcels_can_afford < target_order_ref_mut.base_parcels) {
            // If number of base parcels that user can afford is less
            // than the number they would otherwise buy
            if (base_parcels_can_afford < *base_parcels_to_fill_ref_mut) {
                // Set the remaining number of base parcels to fill as
                // the number they can actually afford
                *base_parcels_to_fill_ref_mut = base_parcels_can_afford;
            };
        };
    }

    /// Verifies that `OrderBook` exists at `host` for given market,
    /// then withdraws collateral from `user`'s market account as needed
    /// to cover a market order. Deposits assets back to `user` after.
    /// See wrapped function `fill_market_order()`.
    ///
    /// # Parameters
    /// * `user`: Address of corresponding user
    /// * `host`: Where corresponding `OrderBook` is hosted
    /// * `custodian_id`: Serial ID of delegated custodian for given
    ///   market account
    /// * `style`: `BUY` or `SELL`
    /// * `max_base_parcels`: The maximum number of base parcels to fill
    /// * `max_quote_units`: The maximum number of quote units to
    ///   exchange during a `BUY`, which may become a limiting factor
    ///   if the incoming user cannot afford to buy `max_base_parcels`
    ///   at market prices.
    fun fill_market_order_from_market_account<B, Q, E>(
        user: address,
        host: address,
        custodian_id: u64,
        style: bool,
        max_base_parcels: u64,
        max_quote_units: u64,
    ) acquires EconiaCapabilityStore, OrderBook {
        // Assert host has an order book
        assert!(exists<OrderBook<B, Q, E>>(host), E_NO_ORDER_BOOK);
        // Borrow mutable reference to order book
        let order_book_ref_mut = borrow_global_mut<OrderBook<B, Q, E>>(host);
        // Get scale factor for book
        let scale_factor = order_book_ref_mut.scale_factor;
        let market_account_info = // Get market account info for order
            user::market_account_info<B, Q, E>(custodian_id);
        // Get an Econia capability
        let econia_capability = get_econia_capability();
        // Get base and quote coin instances for collateral routing
        let (base_coins, quote_coins) = if (style == BUY) ( // If a buy
            coin::zero<B>(), // Does not require base, but needs quote
            user::withdraw_collateral_internal<Q>(user, market_account_info,
                max_quote_units, &econia_capability),
        ) else ( // If a market sell
            // Requires base coins from user
            user::withdraw_collateral_internal<B>(user, market_account_info,
                max_base_parcels * scale_factor, &econia_capability),
            coin::zero<Q>(), // Does not require quote coins from user
        );
        // Fill market order against the book
        fill_market_order<B, Q, E>(order_book_ref_mut, scale_factor, style,
            max_base_parcels, max_quote_units, &mut base_coins,
            &mut quote_coins, &econia_capability);
        // Deposit base coins to user's collateral
        user::deposit_collateral<B>(user, market_account_info, base_coins);
        // Deposit quote coins to user's collateral
        user::deposit_collateral<Q>(user, market_account_info, quote_coins);
    }

    /// Initialize local variables required for filling market orders.
    ///
    /// Inner function for `fill_market_order()`.
    ///
    /// # Parameters
    /// * `order_book_ref_mut`: Mutable reference to corresponding
    ///   `OrderBook`
    /// * `style`: `BUY` or `SELL`
    /// * `max_base_parcels`: The maximum number of base parcels to fill
    ///
    /// # Returns
    /// * `u64`: A counter for the number of base parcels left to fill
    /// * `bool`: Either `ASK` or `BID`
    /// * `&mut CritBitTree`: Mutable reference to orders tree to fill
    ///   against
    /// * `&mut u128`: Mutable reference to spread maker field for given
    ///   `side`
    /// * `u64`: Number of orders in corresponding tree
    /// * `bool`: `LEFT` or `RIGHT` (traversal direction)
    fun fill_market_order_init<B, Q, E>(
        order_book_ref_mut: &mut OrderBook<B, Q, E>,
        style: bool,
        max_base_parcels: u64,
    ): (
        u64,
        bool,
        &mut CritBitTree<Order>,
        &mut u128,
        u64,
        bool
    ) {
        // Declare counter for number of base parcels left to fill
        let base_parcels_to_fill = max_base_parcels;
        // Get side that order fills against, mutable reference to
        // orders tree to fill against, mutable reference to the spread
        // maker for given side, and traversal direction
        let (side, tree_ref_mut, spread_maker_ref_mut, traversal_direction) =
            if (style == BUY) (
            ASK, // If a market buy, fills against asks
            &mut order_book_ref_mut.asks, // Fill against asks tree
            &mut order_book_ref_mut.min_ask, // Asks spread maker
            RIGHT // Successor iteration
        ) else ( // If a market sell
            BID, // Fills against bids, requires base coins
            &mut order_book_ref_mut.bids, // Fill against bids tree
            &mut order_book_ref_mut.max_bid, // Bids spread maker
            LEFT // Predecessor iteration
        );
        // Get number of orders on book for given side
        let n_orders = critbit::length(tree_ref_mut);
        // Return initialized variables
        (base_parcels_to_fill, side, tree_ref_mut, spread_maker_ref_mut,
         n_orders, traversal_direction)
    }

    /// Follow up after processing a fill against an order on the book.
    ///
    /// Inner function for `fill_market_order_traverse_loop()`. Checks
    /// if traversal is still possible, computes new spread maker values
    /// as needed, and determines if loop has hit break condition.
    ///
    /// # Parameters
    /// * `side`: `ASK` or `BID`, side of order on book just processed
    /// * `base_parcels_to_fill`: Counter for base parcels left to fill
    /// * `complete_fill`: `true` if the processed order was completely
    ///   filled
    /// * `traversal_direction`: `LEFT` or `RIGHT`
    /// * `tree_ref_mut`: Mutable reference to orders tree
    /// * `n_orders`: Counter for number of orders in tree, including
    ///   the order that was just processed
    /// * `target_order_id`: The order ID of the target order just
    ///   processed
    /// * `target_order_ref_mut`: Mutable reference to an `Order`.
    ///   Reassigned only when traversal should proceed to the next
    ///   order on the book, otherwise left unmodified. Intended to
    ///   accept as an input a mutable reference to a bogus `Order`.
    /// * `target_parent_index`: Loop variable for iterated traversal
    ///   along outer nodes of a `CritBitTree`
    /// * `target_child_index`: Loop variable for iterated traversal
    ///   along outer nodes of a `CritBitTree`
    ///
    /// # Returns
    /// * `bool`: `true` if should break out of loop after follow up
    /// * `bool`: `true` if just processed a complete fill against
    ///   the last order on the book and it should be popped without
    ///   attempting to traverse
    /// * `u128`: The order ID of the new spread maker for the given
    ///   `side`, if one should be set
    /// * `u64`: Updated count for `n_orders`
    /// * `u128`: Target order ID, updated if traversal proceeds to the
    ///   next order on the book
    /// * `&mut Order`: Mutable reference to next order on the book to
    ///   process, only reassigned when iterated traversal proceeds
    /// * `u64`: Loop variable for iterated traversal along outer nodes
    ///   of a `CritBitTree`, only updated when iterated traversal
    ///   proceeds
    /// * `u64`: Loop variable for iterated traversal along outer nodes
    ///   of a `CritBitTree`, only updated when iterated traversal
    ///   proceeds
    fun fill_market_order_loop_order_follow_up(
        side: bool,
        base_parcels_to_fill: u64,
        complete_fill: bool,
        traversal_direction: bool,
        tree_ref_mut: &mut CritBitTree<Order>,
        n_orders: u64,
        target_order_id: u128,
        target_order_ref_mut: &mut Order,
        target_parent_index: u64,
        target_child_index: u64,
    ): (
        bool,
        bool,
        u128,
        u64,
        u128,
        &mut Order,
        u64,
        u64
    ) {
        // Assume should set new spread maker field to target order ID,
        // that should break out of loop after follow up, and that
        // should not pop an order off the book after followup
        let (new_spread_maker, should_break, should_pop) =
            ( target_order_id,         true,      false);
        if (n_orders == 1) { // If no orders left on book
            if (complete_fill) { // If had a complete fill
                should_pop = true; // Mark that should pop final order
                // Set new spread maker value to default value for side
                new_spread_maker = if (side == ASK) MIN_ASK_DEFAULT else
                    MAX_BID_DEFAULT
            }; // If incomplete fill, use default flags
        } else { // If orders still left on book
            if (complete_fill) { // If target order completely filled
                // Traverse pop to next order on book
                (target_order_id, target_order_ref_mut, target_parent_index,
                 target_child_index,
                 Order{base_parcels: _, user: _, custodian_id: _}) =
                    critbit::traverse_pop_mut(tree_ref_mut, target_order_id,
                        target_parent_index, target_child_index, n_orders,
                        traversal_direction);
                if (base_parcels_to_fill == 0) {
                    // The order ID of the order that was just traversed
                    // to becomes the new spread maker
                    new_spread_maker = target_order_id;
                } else { // If still base parcels left to fill
                    should_break = false; // Should continue looping
                    // Decrement count of orders on book for given side
                    n_orders = n_orders - 1;
                };
            }; // If incomplete fill, use default flags
        };
        // Return updated variables
        (should_break, should_pop, new_spread_maker, n_orders, target_order_id,
         target_order_ref_mut, target_parent_index, target_child_index)
    }

    /// Fill a target order on the book during iterated traversal.
    ///
    /// Inner function for `fill_market_order_traverse_loop()`, where
    /// the "incoming user" (who the market order is for) fills against
    /// a "target order" on the order book.
    ///
    /// # Parameters
    /// * `style`: `BUY` or `SELL`
    /// * `side`: `ASK` if `style` is `BUY`, `BID` if `style` is `ASK`:
    ///   the target order side
    /// * `scale_factor`: Scale factor for given market
    /// * `base_parcels_to_fill_ref_mut`: Mutable reference to ongoing
    ///    counter for base parcels left to fill
    /// * `target_order_id`: Order ID of target order on book
    /// * `target_order_ref_mut`: Mutable reference to target order
    /// * `base_coins_ref_mut`: Mutable reference to incoming user's
    ///   base coins
    /// * `quote_coins_ref_mut`: Mutable reference to incoming user's
    ///   quote coins
    /// * `econia_capability_ref`: Immutable reference to an
    ///   `EconiaCapability` required for internal cross-module calls
    ///
    /// # Returns
    /// * `bool`: `true` if target order is completely filled, else
    ///   `false`
    fun fill_market_order_process_loop_order<B, Q, E>(
        style: bool,
        side: bool,
        scale_factor: u64,
        base_parcels_to_fill_ref_mut: &mut u64,
        target_order_id: u128,
        target_order_ref_mut: &mut Order,
        base_coins_ref_mut: &mut coin::Coin<B>,
        quote_coins_ref_mut: &mut coin::Coin<Q>,
        econia_capability_ref: &EconiaCapability,
    ): (
        bool
    ) {
        // Calculate price of target order
        let target_price = order_id::price(target_order_id);
        // Check, and maybe update, tracker for base parcels to fill
        fill_market_order_check_base_parcels_to_fill(style, target_price,
            quote_coins_ref_mut, target_order_ref_mut,
            base_parcels_to_fill_ref_mut);
        // Target price may be too high for user to afford even one
        // base parcel in the case of a buy, and return incomplete fill
        // if so
        if (*base_parcels_to_fill_ref_mut == 0) return false;
        // Otherwise check if target order will be completely filled
        let complete_fill = (*base_parcels_to_fill_ref_mut >=
            target_order_ref_mut.base_parcels);
        // Calculate number of base parcels filled
        let base_parcels_filled = if (complete_fill)
            // If complete fill, number of base parcels order was for
            target_order_ref_mut.base_parcels else
            // Else, remaining base parcels left to fill
            *base_parcels_to_fill_ref_mut;
        // Decrement counter for number of base parcels to fill
        *base_parcels_to_fill_ref_mut = *base_parcels_to_fill_ref_mut -
            base_parcels_filled;
        // Calculate base and quote coins routed for the fill
        let base_to_route = base_parcels_filled * scale_factor;
        let quote_to_route = base_parcels_filled * target_price;
        // Fill the target user's order
        user::fill_order_internal<B, Q, E>(target_order_ref_mut.user,
            target_order_ref_mut.custodian_id, side, target_order_id,
            complete_fill, base_parcels_filled, base_coins_ref_mut,
            quote_coins_ref_mut, base_to_route, quote_to_route,
            econia_capability_ref);
        // If did not completely fill target order, decrement the number
        // of base parcels it is for by the fill amount (if it was
        // completely filled, it should be popped later)
        if (!complete_fill) target_order_ref_mut.base_parcels =
            target_order_ref_mut.base_parcels - base_parcels_filled;
        complete_fill // Return if target order was completely filled
    }

    /// Fill a market order by traversing along the orders tree.
    ///
    /// Inner function for `fill_market_order()`. During iterated
    /// traversal, the "incoming user" (who places the market order or
    /// who has the order placed on their behalf by a custodian) has
    /// their order filled against the "target user" who has a "target
    /// position" on the order book.
    ///
    /// # Parameters
    /// * `style`: `BUY` or `SELL`
    /// * `side`: `ASK` if `style` is `BUY`, `BID` if `style` is `ASK`:
    ///   the target order side
    /// * `scale_factor`: Scale factor for given market
    /// * `tree_ref_mut`: Mutable reference to orders tree for given
    ///   `side`
    /// * `traversal_direction`: `LEFT` or `RIGHT`
    /// * `n_orders`: Counter for number of orders in tree
    /// * `spread_maker_ref_mut`: Mutable reference to field tracking
    ///   spread maker on given `side`
    /// * `base_parcels_to_fill`: Initialized counter for base parcels
    ///    left to fill
    /// * `base_coins_ref_mut`: Mutable reference to incoming user's
    ///   base coins
    /// * `quote_coins_ref_mut`: Mutable reference to incoming user's
    ///   quote coins
    /// * `econia_capability_ref`: Immutable reference to an
    ///   `EconiaCapability` required for internal cross-module calls
    fun fill_market_order_traverse_loop<B, Q, E>(
        style: bool,
        side: bool,
        scale_factor: u64,
        tree_ref_mut: &mut CritBitTree<Order>,
        traversal_direction: bool,
        n_orders: u64,
        spread_maker_ref_mut: &mut u128,
        base_parcels_to_fill: u64,
        base_coins_ref_mut: &mut coin::Coin<B>,
        quote_coins_ref_mut: &mut coin::Coin<Q>,
        econia_capability_ref: &EconiaCapability
    ) {
        // Initialize iterated traversal, storing order ID of target
        // order, mutable reference to target order, the parent field
        // of the target node, and child field index of target node
        let (target_order_id, target_order_ref_mut, target_parent_index,
             target_child_index) = critbit::traverse_init_mut(
                tree_ref_mut, traversal_direction);
        // Declare a null order for generating default mutable reference
        let null_order = Order{user: @0x0, custodian_id: 0, base_parcels: 0};
        loop { // Begin traversal loop
            // Process the order for current iteration, storing flag for
            // if the target order was completely filled
            let complete_fill = fill_market_order_process_loop_order<B, Q, E>(
                style, side, scale_factor, &mut base_parcels_to_fill,
                target_order_id, target_order_ref_mut, base_coins_ref_mut,
                quote_coins_ref_mut, econia_capability_ref);
            // Declare variables for if should break out of loop, if
            // should pop the last order in the tree, and the value for
            // a new spread maker if one is generated
            let (should_break, should_pop, new_spread_maker);
            // Follow up on order processing
            (should_break, should_pop, new_spread_maker, n_orders,
             target_order_id, target_order_ref_mut, target_parent_index,
             target_child_index) = fill_market_order_loop_order_follow_up(
                side, base_parcels_to_fill, complete_fill, traversal_direction,
                tree_ref_mut, n_orders, target_order_id, &mut null_order,
                target_parent_index, target_child_index);
            if (should_break) { // If should break out of loop
                // Clean up as needed before breaking out of loop
                fill_market_order_break_cleanup(null_order,
                    spread_maker_ref_mut, new_spread_maker, should_pop,
                    tree_ref_mut, target_order_id);
                break // Break out of loop
            };
        };
    }

    // Private functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // SDK generation >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Simple representation of an order, for SDK generation
    struct SimpleOrder has copy, drop {
        /// Price encoded in corresponding `Order`'s order ID
        price: u64,
        /// Number of base parcels the order is for
        base_parcels: u64
    }

    /// Represents a price level formed by one or more `OrderSimple`s
    struct PriceLevel has copy, drop {
        /// Price of all orders in the price level
        price: u64,
        /// Net base parcels across all `OrderSimple`s in the level
        base_parcels: u64
    }

    /// Index `Order`s from `order_book_ref_mut` into vector of
    /// `SimpleOrder`s, sorted by price-time priority per
    /// `get_orders_sdk`, for each side.
    ///
    /// # Returns
    /// * `vector<SimpleOrder>`: Price-time sorted asks
    /// * `vector<SimpleOrder>`: Price-time sorted bids
    fun book_orders_sdk<B, Q, E>(
        order_book_ref_mut: &mut OrderBook<B, Q, E>
    ): (
        vector<SimpleOrder>,
        vector<SimpleOrder>
    ) {
        (get_orders_sdk<B, Q, E>(order_book_ref_mut, ASK),
         get_orders_sdk<B, Q, E>(order_book_ref_mut, BID))
    }

    /// Index `OrderBook` from `order_book_ref_mut` into vector of
    /// `PriceLevels` for each side.
    ///
    /// # Returns
    /// * `vector<PriceLevel>`: Ask price levels
    /// * `vector<PriceLevel>`: Bid price levels
    fun book_price_levels_sdk<B, Q, E>(
        order_book_ref_mut: &mut OrderBook<B, Q, E>
    ): (
        vector<PriceLevel>,
        vector<PriceLevel>
    ) {
        (get_price_levels_sdk(get_orders_sdk(order_book_ref_mut, ASK)),
         get_price_levels_sdk(get_orders_sdk(order_book_ref_mut, BID)))
    }

    /// Index `Order`s in `order_book_ref_mut` into a `vector` of
    /// `OrderSimple`s sorted by price-time priority, beginning with the
    /// spread maker: if `side` is `ASK`, first element in vector is the
    /// oldest ask at the minimum ask price, and if `side` is `BID`,
    /// first element in vector is the oldest bid at the maximum bid
    /// price. Requires mutable reference to `OrderBook` because
    /// `CritBitTree` traversal is not implemented immutably (at least
    /// as of the time of this writing). Only for SDK generation.
    fun get_orders_sdk<B, Q, E>(
        order_book_ref_mut: &mut OrderBook<B, Q, E>,
        side: bool
    ): vector<SimpleOrder> {
        // Initialize empty vector
        let simple_orders = vector::empty<SimpleOrder>();
        // Define orders tree and traversal direction base on side
        let (tree_ref_mut, traversal_direction) = if (side == ASK)
            // If asks, use asks tree with successor iteration
            (&mut order_book_ref_mut.asks, RIGHT) else
            // If bids, use bids tree with predecessor iteration
            (&mut order_book_ref_mut.bids, LEFT);
        // If no positions in tree, return empty vector
        if (critbit::is_empty(tree_ref_mut)) return simple_orders;
        // Calculate number of traversals possible
        let remaining_traversals = critbit::length(tree_ref_mut) - 1;
        // Initialize traversal: get target order ID, mutable reference
        // to target order, and the index of the target node's parent
        let (target_id, target_order_ref_mut, target_parent_index, _) =
            critbit::traverse_init_mut(tree_ref_mut, traversal_direction);
        loop { // Loop over all orders in tree
            vector::push_back(&mut simple_orders, SimpleOrder{
                price: order_id::price(target_id),
                base_parcels: target_order_ref_mut.base_parcels
            }); // Push back corresponding simple order onto vector
            // Return simple orders vector if unable to traverse
            if (remaining_traversals == 0) return simple_orders;
            // Otherwise traverse to next order in the tree
            (target_id, target_order_ref_mut, target_parent_index, _) =
                critbit::traverse_mut(tree_ref_mut, target_id,
                    target_parent_index, traversal_direction);
            // Decrement number of remaining traversals
            remaining_traversals = remaining_traversals - 1;
        }
    }

    /// Index output of `get_orders_sdk()` into a vector of `PriceLevel`
    fun get_price_levels_sdk(
        simple_orders: vector<SimpleOrder>
    ): vector<PriceLevel> {
        // Initialize empty vector of price levels
        let price_levels = vector::empty<PriceLevel>();
        // Return empty vector if no simple orders to index
        if (vector::is_empty(&simple_orders)) return price_levels;
        // Get immutable reference to first simple order in vector
        let simple_order_ref = vector::borrow(&simple_orders, 0);
        // Set level price to that from first simple order
        let level_price = simple_order_ref.price;
        // Set level base parcels counter to that of first simple order
        let level_base_parcels = simple_order_ref.base_parcels;
        // Get number of simple orders to index
        let n_simple_orders = vector::length(&simple_orders);
        let simple_order_index = 1; // Start loop at the next order
        // While there are simple orders left to index
        while (simple_order_index < n_simple_orders) {
            // Borrow immutable reference to order for current iteration
            simple_order_ref =
                vector::borrow(&simple_orders, simple_order_index);
            // If on new level
            if (simple_order_ref.price != level_price) {
                // Store last price level in vector
                vector::push_back(&mut price_levels, PriceLevel{
                    price: level_price, base_parcels: level_base_parcels});
                // Start tracking new price level with given order
                (level_price, level_base_parcels) = (
                    simple_order_ref.price, simple_order_ref.base_parcels)
            } else { // If same price as last checked
                // Increment count of base parcels for current level
                level_base_parcels =
                    level_base_parcels + simple_order_ref.base_parcels;
            };
            // Iterate again, on next simple order in vector
            simple_order_index = simple_order_index + 1;
        }; // No more simple orders left to index
        // Store final price level in vector
        vector::push_back(&mut price_levels, PriceLevel{
            price: level_price, base_parcels: level_base_parcels});
        price_levels // Return sorted vector of price levels
    }

    /// Calculate expected result of swap against an `OrderBook`.
    ///
    /// # Parameters
    /// * `order_book_ref_mut`: Mutable reference to an `OrderBook`
    /// * `style`: `BUY` or `SELL`
    /// * `coins_in`: Quote coins to spend if style is `BUY`, and base
    ///   coins to sell if style is `SELL`
    ///
    /// # Returns
    /// * `u64`: Max base coins that can be purchased with `coins_in`
    ///   quote coins if `style` is `BUY`, else max quote coins that can
    ///   be received in exchange for selling `coins_in` base coins.
    /// * `u64`: Leftover `coins_in`, if not enough depth on book for a
    ///   complete fill, or if integer truncation results in being
    ///   unable to fill an entire base parcel.
    fun simulate_swap_sdk<B, Q, E>(
        order_book_ref_mut: &mut OrderBook<B, Q, E>,
        style: bool,
        coins_in: u64
    ): (
        u64,
        u64
    ) {
        // If a swap buy, fills against asks, else bids
        let (side) = if (style == BUY) ASK else BID;
        // Get orders sorted by price-time priority
        let simple_orders = get_orders_sdk<B, Q, E>(order_book_ref_mut, side);
        // If no orders on book, return that 0 swaps made
        if (vector::is_empty(&simple_orders)) return (0, coins_in);
        // Get order book scale factor
        let scale_factor = order_book_ref_mut.scale_factor;
        // Initialize counter for in coins left, out coins received,
        // counter for vector loop index, and number of orders
        let (coins_in_left, coins_out, simple_order_index, n_orders) =
            (coins_in, 0, 0, vector::length(&simple_orders));
        loop { // Loop over all orders
            // Borrow immutable reference to order for current iteration
            let simple_order =
                vector::borrow(&simple_orders, simple_order_index);
            // Declare variables for base parcels filled, and if should
            // return after current iteration
            let (base_parcels_filled, should_return);
            // Set base parcels filled multipliers based on style
            let (coins_in_multiplier, coins_out_multiplier) =
                // If sell, get base coins and expend quote coins
                if (style == SELL) (scale_factor, simple_order.price) else
                    // If buy, get quote coins and expend base coins
                    (simple_order.price, scale_factor);
            if (style == SELL) { // If selling base coins
                // Calculate base parcels swap seller has
                let base_parcels_on_hand = coins_in_left / scale_factor;
                // Caculate base parcels filled against order and if
                // should return after current loop iteration
                (base_parcels_filled, should_return) =
                    // If more than enough base parcels on hand for a
                    // complete fill against the target bid
                    if (base_parcels_on_hand > simple_order.base_parcels)
                    // Complete fill, so continue
                    (simple_order.base_parcels, false) else
                    // Fills all parcels on hand, so return
                    (base_parcels_on_hand, true);
            } else { // If buying base coins
                // Calculate number of base parcels user can afford at
                // order price
                let base_parcels_can_afford =
                    coins_in_left / simple_order.price;
                // Caculate base parcels filled against order and if
                // should return after current loop iteration
                (base_parcels_filled, should_return) =
                    // If cannot afford to buy all base parcels in order
                    if (simple_order.base_parcels > base_parcels_can_afford)
                    // Only fills base parcels can afford, so return
                    (base_parcels_can_afford, true) else
                    // Fills all base parcels in order, so continue
                    (simple_order.base_parcels, false);
            };
            // Decrement coins in by base parcels times multiplier
            coins_in_left = coins_in_left -
                base_parcels_filled * coins_in_multiplier;
            // Increment coins out by base parcels times multiplier
            coins_out = coins_out + base_parcels_filled * coins_out_multiplier;
            // Increment loop counter
            simple_order_index = simple_order_index + 1;
            // If done looping, return coins out and coins in left
            if (should_return || simple_order_index == n_orders)
                return (coins_out, coins_in_left)
        }
    }

    // SDK generation <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Below constants for end-to-end market order fill testing
    #[test_only]
    const USER_0_CUSTODIAN_ID: u64 = 0; // No custodian flag

    // Test-only constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    /// Initialize a `user` to trade on `<BC, QC, E1>`, hosted by
    /// `econia`, with market account having `custodian_id`, and fund
    /// with `base_coins` and `quote_coins`
    fun init_funded_user(
        econia: &signer,
        user: &signer,
        custodian_id: u64,
        base_coins: u64,
        quote_coins: u64
    ) {
        // Set custodian ID as in bounds
        registry::set_registered_custodian(custodian_id);
        // Reguster user to trade on the market
        user::register_market_account<BC, QC, E1>(user, custodian_id);
        // Get market account info
        let market_account_info =
            user::market_account_info<BC, QC, E1>(custodian_id);
        // Deposit base coin collateral
        user::deposit_collateral<BC>(address_of(user), market_account_info,
            coins::mint<BC>(econia, base_coins));
        // Deposit quote coin collateral
        user::deposit_collateral<QC>(address_of(user), market_account_info,
            coins::mint<QC>(econia, quote_coins));
    }

    #[test_only]
    /// Initialize all users for trading on the test market
    /// `<BC, QC, E1>` hosted by `econia`, then place limit orders
    /// for `user_1`, `user_2`, `user_3`, on `side`, returning the order
    /// ID for each respective position
    fun init_market_test(
        side: bool,
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer,
    ): (
        u128,
        u128,
        u128
    ) acquires EconiaCapabilityStore, OrderBook {
        coins::init_coin_types(econia); // Initialize coin types
        registry::init_registry(econia); // Initialize registry
        // Initialize Econia capability store
        init_econia_capability_store(econia);
        // Register test market with Econia as host
        register_market<BC, QC, E1>(econia);
        // Initialize funded users
        init_funded_user(econia, user_0, USER_0_CUSTODIAN_ID,
            USER_0_START_BASE, USER_0_START_QUOTE);
        init_funded_user(econia, user_1, USER_1_CUSTODIAN_ID,
            USER_1_START_BASE, USER_1_START_QUOTE);
        init_funded_user(econia, user_2, USER_2_CUSTODIAN_ID,
            USER_2_START_BASE, USER_2_START_QUOTE);
        init_funded_user(econia, user_3, USER_3_CUSTODIAN_ID,
            USER_3_START_BASE, USER_3_START_QUOTE);
        // Define user order prices and sizes based on market side
        let user_1_order_price = if (side == ASK)
            USER_1_ASK_PRICE else USER_1_BID_PRICE;
        let user_2_order_price = if (side == ASK)
            USER_2_ASK_PRICE else USER_2_BID_PRICE;
        let user_3_order_price = if (side == ASK)
            USER_3_ASK_PRICE else USER_3_BID_PRICE;
        let user_1_order_size = if (side == ASK)
            USER_1_ASK_SIZE else USER_1_BID_SIZE;
        let user_2_order_size = if (side == ASK)
            USER_2_ASK_SIZE else USER_2_BID_SIZE;
        let user_3_order_size = if (side == ASK)
            USER_3_ASK_SIZE else USER_3_BID_SIZE;
        // Define order ID for each user's upcoming order
        let order_id_1 = order_id::order_id(user_1_order_price,
            USER_1_SERIAL_ID, side);
        let order_id_2 = order_id::order_id(user_2_order_price,
            USER_2_SERIAL_ID, side);
        let order_id_3 = order_id::order_id(user_3_order_price,
            USER_3_SERIAL_ID, side);
        // Get custodian capabilities
        let custodian_capability_1 =
            registry::get_custodian_capability(USER_1_CUSTODIAN_ID);
        let custodian_capability_2 =
            registry::get_custodian_capability(USER_2_CUSTODIAN_ID);
        let custodian_capability_3 =
            registry::get_custodian_capability(USER_3_CUSTODIAN_ID);
        // Place limit orders for given side
        place_limit_order_custodian<BC, QC, E1>(@user_1, @econia, side,
            user_1_order_size, user_1_order_price, &custodian_capability_1);
        place_limit_order_custodian<BC, QC, E1>(@user_2, @econia, side,
            user_2_order_size, user_2_order_price, &custodian_capability_2);
        place_limit_order_custodian<BC, QC, E1>(@user_3, @econia, side,
            user_3_order_size, user_3_order_price, &custodian_capability_3);
        // Destroy custodian capabilities
        registry::destroy_custodian_capability(custodian_capability_1);
        registry::destroy_custodian_capability(custodian_capability_2);
        registry::destroy_custodian_capability(custodian_capability_3);
        (order_id_1, order_id_2, order_id_3) // Return order IDs
    }

    // Test-only functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify post-fill state for user submitting market buy where the
    /// specified `max_quote_units` limits them to a complete fill on
    /// first order
    fun test_fill_market_order_complete_fill_quote_limiting(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = BUY; // define market order style
        let side =  ASK; // define side of book orders fill against
        let max_base_parcels = 1000; // define max base parcels to fill
        // define max quote units if buy
        let max_quote_units = USER_1_ASK_PRICE * USER_1_ASK_SIZE;
        // Calculate number of base parcels filled
        let base_parcels_filled = USER_1_ASK_SIZE;
        // Calculate number of base coins routed
        let base_routed = base_parcels_filled * SCALE_FACTOR;
        // Calculate number of quote coins routed
        let quote_routed = base_parcels_filled * USER_1_ASK_PRICE;
        assert!( // assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order id of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        let custodian_capability = // Get mock custodian capability
            registry::get_custodian_capability(USER_0_CUSTODIAN_ID);
        // Attempt market order fill, generating mock custodian
        // capability that cannot make in practice but which can use to
        // check invocation of custodian placement function
        fill_market_order_custodian<BC, QC, E1>(@user_0, @econia, style,
            max_base_parcels, max_quote_units, &custodian_capability);
        // Destroy capability
        registry::destroy_custodian_capability(custodian_capability);
        // Assert order book state
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        let (order_base_parcels_2, order_user_2, order_custodian_id_2) =
            order_fields_test<BC, QC, E1>(@econia, order_id_2, side);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_2 ==  USER_2_ASK_SIZE, 0);
        assert!(order_base_parcels_3 ==  USER_3_ASK_SIZE, 0);
        assert!(        order_user_2 == @user_2, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_2 ==  USER_2_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) == order_id_2, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == USER_0_START_BASE + base_routed, 0);
        assert!(      base_total_0 == USER_0_START_BASE + base_routed, 0);
        assert!(  base_available_0 == USER_0_START_BASE + base_routed, 0);
        assert!(quote_collateral_0 == USER_0_START_QUOTE - quote_routed, 0);
        assert!(     quote_total_0 == USER_0_START_QUOTE - quote_routed, 0);
        assert!( quote_available_0 == USER_0_START_QUOTE - quote_routed, 0);
        assert!( base_collateral_1 == USER_1_START_BASE - base_routed, 0);
        assert!(      base_total_1 == USER_1_START_BASE - base_routed, 0);
        assert!(  base_available_1 == USER_1_START_BASE - base_routed, 0);
        assert!(quote_collateral_1 == USER_1_START_QUOTE + quote_routed, 0);
        assert!(     quote_total_1 == USER_1_START_QUOTE + quote_routed, 0);
        assert!( quote_available_1 == USER_1_START_QUOTE + quote_routed, 0);
        assert!( base_collateral_2 == USER_2_START_BASE, 0);
        assert!(      base_total_2 == USER_2_START_BASE, 0);
        assert!(  base_available_2 == USER_2_START_BASE -
            USER_2_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_2 == USER_2_START_QUOTE, 0);
        assert!(     quote_total_2 == USER_2_START_QUOTE, 0);
        assert!( quote_available_2 == USER_2_START_QUOTE, 0);
        assert!( base_collateral_3 == USER_3_START_BASE, 0);
        assert!(      base_total_3 == USER_3_START_BASE, 0);
        assert!(  base_available_3 == USER_3_START_BASE -
            USER_3_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_3 == USER_3_START_QUOTE, 0);
        assert!(     quote_total_3 == USER_3_START_QUOTE, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE, 0);
        // Assert user order sizes (or that they have been popped)
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        let user_2_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_2,
                USER_2_CUSTODIAN_ID, side, order_id_2);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_2_order_base_parcels == USER_2_ASK_SIZE, 0);
        assert!(user_3_order_base_parcels == USER_3_ASK_SIZE, 0);
    }

    #[test(user = @user)]
    #[expected_failure(abort_code = 4)]
    /// Verify failure for no such order book
    fun test_fill_market_order_no_book(
        user: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        // Attempt invalid market order fill
        fill_market_order_user<QC, BC, E1>(user, @econia, BUY, 100, 200);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify unmodified user state for nothing to fill
    fun test_fill_market_order_no_fill_base_parcels(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = SELL; // Define market order style
        let side =  BID; // Define side of book orders fill against
        let max_base_parcels = 0; // Define max base parcels to fill
        let max_quote_units = 100; // Define max quote units if buy
        assert!( // Assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert order book state
        let (order_base_parcels_1, order_user_1, order_custodian_id_1) =
            order_fields_test<BC, QC, E1>(@econia, order_id_1, side);
        let (order_base_parcels_2, order_user_2, order_custodian_id_2) =
            order_fields_test<BC, QC, E1>(@econia, order_id_2, side);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_1 ==  USER_1_BID_SIZE, 0);
        assert!(order_base_parcels_2 ==  USER_2_BID_SIZE, 0);
        assert!(order_base_parcels_3 ==  USER_3_BID_SIZE, 0);
        assert!(        order_user_1 == @user_1, 0);
        assert!(        order_user_2 == @user_2, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_1 ==  USER_1_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_2 ==  USER_2_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) == order_id_1, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == USER_0_START_BASE, 0);
        assert!(      base_total_0 == USER_0_START_BASE, 0);
        assert!(  base_available_0 == USER_0_START_BASE, 0);
        assert!(quote_collateral_0 == USER_0_START_QUOTE, 0);
        assert!(     quote_total_0 == USER_0_START_QUOTE, 0);
        assert!( quote_available_0 == USER_0_START_QUOTE, 0);
        assert!( base_collateral_1 == USER_1_START_BASE, 0);
        assert!(      base_total_1 == USER_1_START_BASE, 0);
        assert!(  base_available_1 == USER_1_START_BASE, 0);
        assert!(quote_collateral_1 == USER_1_START_QUOTE, 0);
        assert!(     quote_total_1 == USER_1_START_QUOTE, 0);
        assert!( quote_available_1 == USER_1_START_QUOTE
            - USER_1_BID_SIZE * USER_1_BID_PRICE, 0);
        assert!( base_collateral_2 == USER_2_START_BASE, 0);
        assert!(      base_total_2 == USER_2_START_BASE, 0);
        assert!(  base_available_2 == USER_2_START_BASE, 0);
        assert!(quote_collateral_2 == USER_2_START_QUOTE, 0);
        assert!(     quote_total_2 == USER_2_START_QUOTE, 0);
        assert!( quote_available_2 == USER_2_START_QUOTE
            - USER_2_BID_SIZE * USER_2_BID_PRICE, 0);
        assert!( base_collateral_3 == USER_3_START_BASE, 0);
        assert!(      base_total_3 == USER_3_START_BASE, 0);
        assert!(  base_available_3 == USER_3_START_BASE, 0);
        assert!(quote_collateral_3 == USER_3_START_QUOTE, 0);
        assert!(     quote_total_3 == USER_3_START_QUOTE, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE
            - USER_3_BID_SIZE * USER_3_BID_PRICE, 0);
        // Assert user order sizes
        let user_1_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_1,
                USER_1_CUSTODIAN_ID, side, order_id_1);
        let user_2_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_2,
                USER_2_CUSTODIAN_ID, side, order_id_2);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_1_order_base_parcels == USER_1_BID_SIZE, 0);
        assert!(user_2_order_base_parcels == USER_2_BID_SIZE, 0);
        assert!(user_3_order_base_parcels == USER_3_BID_SIZE, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify unmodified user state for user submitting market buy but
    /// not allowing enough quote coins to fill even one base parcel
    fun test_fill_market_order_no_fill_cant_afford(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = BUY; // define market order style
        let side =  ASK; // define side of book orders fill against
        let max_base_parcels = 100; // define max base parcels to fill
        let max_quote_units = 1; // define max quote units if buy
        assert!( // assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert order book state
        let (order_base_parcels_1, order_user_1, order_custodian_id_1) =
            order_fields_test<BC, QC, E1>(@econia, order_id_1, side);
        let (order_base_parcels_2, order_user_2, order_custodian_id_2) =
            order_fields_test<BC, QC, E1>(@econia, order_id_2, side);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_1 ==  USER_1_ASK_SIZE, 0);
        assert!(order_base_parcels_2 ==  USER_2_ASK_SIZE, 0);
        assert!(order_base_parcels_3 ==  USER_3_ASK_SIZE, 0);
        assert!(        order_user_1 == @user_1, 0);
        assert!(        order_user_2 == @user_2, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_1 ==  USER_1_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_2 ==  USER_2_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) == order_id_1, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == USER_0_START_BASE, 0);
        assert!(      base_total_0 == USER_0_START_BASE, 0);
        assert!(  base_available_0 == USER_0_START_BASE, 0);
        assert!(quote_collateral_0 == USER_0_START_QUOTE, 0);
        assert!(     quote_total_0 == USER_0_START_QUOTE, 0);
        assert!( quote_available_0 == USER_0_START_QUOTE, 0);
        assert!( base_collateral_1 == USER_1_START_BASE, 0);
        assert!(      base_total_1 == USER_1_START_BASE, 0);
        assert!(  base_available_1 == USER_1_START_BASE -
            USER_1_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_1 == USER_1_START_QUOTE, 0);
        assert!(     quote_total_1 == USER_1_START_QUOTE, 0);
        assert!( quote_available_1 == USER_1_START_QUOTE, 0);
        assert!( base_collateral_2 == USER_2_START_BASE, 0);
        assert!(      base_total_2 == USER_2_START_BASE, 0);
        assert!(  base_available_2 == USER_2_START_BASE -
            USER_2_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_2 == USER_2_START_QUOTE, 0);
        assert!(     quote_total_2 == USER_2_START_QUOTE, 0);
        assert!( quote_available_2 == USER_2_START_QUOTE, 0);
        assert!( base_collateral_3 == USER_3_START_BASE, 0);
        assert!(      base_total_3 == USER_3_START_BASE, 0);
        assert!(  base_available_3 == USER_3_START_BASE -
            USER_3_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_3 == USER_3_START_QUOTE, 0);
        assert!(     quote_total_3 == USER_3_START_QUOTE, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE, 0);
        // Assert user order sizes
        let user_1_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_1,
                USER_1_CUSTODIAN_ID, side, order_id_1);
        let user_2_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_2,
                USER_2_CUSTODIAN_ID, side, order_id_2);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_1_order_base_parcels == USER_1_ASK_SIZE, 0);
        assert!(user_2_order_base_parcels == USER_2_ASK_SIZE, 0);
        assert!(user_3_order_base_parcels == USER_3_ASK_SIZE, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify unmodified user state for nothing to fill (trying to
    /// fill side without orders)
    fun test_fill_market_order_no_fill_empty_tree(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = SELL; // Define market order style
        let side =  BID; // Define side of book orders fill against
        let max_base_parcels = 50; // Define max base parcels to fill
        let max_quote_units = 100; // Define max quote units if buy
        assert!( // Assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Attempt market order fill on opposite side of book (empty)
        fill_market_order_user<BC, QC, E1>(user_0, @econia, !style,
            max_base_parcels, max_quote_units);
        // Assert order book state
        let (order_base_parcels_1, order_user_1, order_custodian_id_1) =
            order_fields_test<BC, QC, E1>(@econia, order_id_1, side);
        let (order_base_parcels_2, order_user_2, order_custodian_id_2) =
            order_fields_test<BC, QC, E1>(@econia, order_id_2, side);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_1 ==  USER_1_BID_SIZE, 0);
        assert!(order_base_parcels_2 ==  USER_2_BID_SIZE, 0);
        assert!(order_base_parcels_3 ==  USER_3_BID_SIZE, 0);
        assert!(        order_user_1 == @user_1, 0);
        assert!(        order_user_2 == @user_2, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_1 ==  USER_1_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_2 ==  USER_2_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) == order_id_1, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == USER_0_START_BASE, 0);
        assert!(      base_total_0 == USER_0_START_BASE, 0);
        assert!(  base_available_0 == USER_0_START_BASE, 0);
        assert!(quote_collateral_0 == USER_0_START_QUOTE, 0);
        assert!(     quote_total_0 == USER_0_START_QUOTE, 0);
        assert!( quote_available_0 == USER_0_START_QUOTE, 0);
        assert!( base_collateral_1 == USER_1_START_BASE, 0);
        assert!(      base_total_1 == USER_1_START_BASE, 0);
        assert!(  base_available_1 == USER_1_START_BASE, 0);
        assert!(quote_collateral_1 == USER_1_START_QUOTE, 0);
        assert!(     quote_total_1 == USER_1_START_QUOTE, 0);
        assert!( quote_available_1 == USER_1_START_QUOTE
            - USER_1_BID_SIZE * USER_1_BID_PRICE, 0);
        assert!( base_collateral_2 == USER_2_START_BASE, 0);
        assert!(      base_total_2 == USER_2_START_BASE, 0);
        assert!(  base_available_2 == USER_2_START_BASE, 0);
        assert!(quote_collateral_2 == USER_2_START_QUOTE, 0);
        assert!(     quote_total_2 == USER_2_START_QUOTE, 0);
        assert!( quote_available_2 == USER_2_START_QUOTE
            - USER_2_BID_SIZE * USER_2_BID_PRICE, 0);
        assert!( base_collateral_3 == USER_3_START_BASE, 0);
        assert!(      base_total_3 == USER_3_START_BASE, 0);
        assert!(  base_available_3 == USER_3_START_BASE, 0);
        assert!(quote_collateral_3 == USER_3_START_QUOTE, 0);
        assert!(     quote_total_3 == USER_3_START_QUOTE, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE
            - USER_3_BID_SIZE * USER_3_BID_PRICE, 0);
        // Assert user order sizes
        let user_1_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_1,
                USER_1_CUSTODIAN_ID, side, order_id_1);
        let user_2_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_2,
                USER_2_CUSTODIAN_ID, side, order_id_2);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_1_order_base_parcels == USER_1_BID_SIZE, 0);
        assert!(user_2_order_base_parcels == USER_2_BID_SIZE, 0);
        assert!(user_3_order_base_parcels == USER_3_BID_SIZE, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify unmodified user state for nothing to fill
    fun test_fill_market_order_no_fill_quote_units(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = BUY; // Define market order style
        let side =  ASK; // Define side of book orders fill against
        let max_base_parcels = 20; // Define max base parcels to fill
        let max_quote_units = 0; // Define max quote units if buy
        assert!( // Assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert order book state
        let (order_base_parcels_1, order_user_1, order_custodian_id_1) =
            order_fields_test<BC, QC, E1>(@econia, order_id_1, side);
        let (order_base_parcels_2, order_user_2, order_custodian_id_2) =
            order_fields_test<BC, QC, E1>(@econia, order_id_2, side);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_1 ==  USER_1_ASK_SIZE, 0);
        assert!(order_base_parcels_2 ==  USER_2_ASK_SIZE, 0);
        assert!(order_base_parcels_3 ==  USER_3_ASK_SIZE, 0);
        assert!(        order_user_1 == @user_1, 0);
        assert!(        order_user_2 == @user_2, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_1 ==  USER_1_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_2 ==  USER_2_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) == order_id_1, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == USER_0_START_BASE, 0);
        assert!(      base_total_0 == USER_0_START_BASE, 0);
        assert!(  base_available_0 == USER_0_START_BASE, 0);
        assert!(quote_collateral_0 == USER_0_START_QUOTE, 0);
        assert!(     quote_total_0 == USER_0_START_QUOTE, 0);
        assert!( quote_available_0 == USER_0_START_QUOTE, 0);
        assert!( base_collateral_1 == USER_1_START_BASE, 0);
        assert!(      base_total_1 == USER_1_START_BASE, 0);
        assert!(  base_available_1 == USER_1_START_BASE -
            USER_1_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_1 == USER_1_START_QUOTE, 0);
        assert!(     quote_total_1 == USER_1_START_QUOTE, 0);
        assert!( quote_available_1 == USER_1_START_QUOTE, 0);
        assert!( base_collateral_2 == USER_2_START_BASE, 0);
        assert!(      base_total_2 == USER_2_START_BASE, 0);
        assert!(  base_available_2 == USER_2_START_BASE -
            USER_2_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_2 == USER_2_START_QUOTE, 0);
        assert!(     quote_total_2 == USER_2_START_QUOTE, 0);
        assert!( quote_available_2 == USER_2_START_QUOTE, 0);
        assert!( base_collateral_3 == USER_3_START_BASE, 0);
        assert!(      base_total_3 == USER_3_START_BASE, 0);
        assert!(  base_available_3 == USER_3_START_BASE -
            USER_3_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_3 == USER_3_START_QUOTE, 0);
        assert!(     quote_total_3 == USER_3_START_QUOTE, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE, 0);
        // Assert user order sizes
        let user_1_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_1,
                USER_1_CUSTODIAN_ID, side, order_id_1);
        let user_2_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_2,
                USER_2_CUSTODIAN_ID, side, order_id_2);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_1_order_base_parcels == USER_1_ASK_SIZE, 0);
        assert!(user_2_order_base_parcels == USER_2_ASK_SIZE, 0);
        assert!(user_3_order_base_parcels == USER_3_ASK_SIZE, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify post-trade state for filling through all price levels
    /// except the final order, for filling against bids
    fun test_fill_market_order_partial_fill_final_bid(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = SELL; // Define market order style
        let side =  BID; // Define side of book orders fill against
        // Define partial fill against user 3
        let user_3_fill_size = USER_3_BID_SIZE - 1;
        let max_base_parcels = USER_1_BID_SIZE + USER_2_BID_SIZE +
            (user_3_fill_size); // Define max base parcels to fill
        let max_quote_units = 0; // Define max quote units if buy
        // Define base/quoute coins routed for each order on book
        let user_1_base_routed  = USER_1_BID_SIZE * SCALE_FACTOR;
        let user_1_quote_routed = USER_1_BID_SIZE * USER_1_BID_PRICE;
        let user_2_base_routed  = USER_2_BID_SIZE * SCALE_FACTOR;
        let user_2_quote_routed = USER_2_BID_SIZE * USER_2_BID_PRICE;
        let user_3_base_routed  = user_3_fill_size * SCALE_FACTOR;
        let user_3_quote_routed = user_3_fill_size * USER_3_BID_PRICE;
        // Calculate end coin amounts for each user
        let user_0_end_base = USER_0_START_BASE - (user_1_base_routed +
            user_2_base_routed + user_3_base_routed);
        let user_0_end_quote = USER_0_START_QUOTE + (user_1_quote_routed +
            user_2_quote_routed + user_3_quote_routed);
        let user_1_end_base  = USER_1_START_BASE  + user_1_base_routed;
        let user_1_end_quote = USER_1_START_QUOTE - user_1_quote_routed;
        let user_2_end_base  = USER_2_START_BASE  + user_2_base_routed;
        let user_2_end_quote = USER_2_START_QUOTE - user_2_quote_routed;
        let user_3_end_base  = USER_3_START_BASE  + user_3_base_routed;
        let user_3_end_quote = USER_3_START_QUOTE - user_3_quote_routed;
        assert!( // Assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Assert all orders on book
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_2), 0);
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_3), 0);
        // Assert users have orders registered
        assert!(user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        assert!(user::has_order_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID, side, order_id_2), 0);
        assert!(user::has_order_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID, side, order_id_3), 0);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert all orders taken off book except final one
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_2), 0);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_3 ==
            USER_3_BID_SIZE - user_3_fill_size, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        // Assert spread maker updated
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) ==
            order_id_3, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == user_0_end_base, 0);
        assert!(      base_total_0 == user_0_end_base, 0);
        assert!(  base_available_0 == user_0_end_base, 0);
        assert!(quote_collateral_0 == user_0_end_quote, 0);
        assert!(     quote_total_0 == user_0_end_quote, 0);
        assert!( quote_available_0 == user_0_end_quote, 0);
        assert!( base_collateral_1 == user_1_end_base, 0);
        assert!(      base_total_1 == user_1_end_base, 0);
        assert!(  base_available_1 == user_1_end_base, 0);
        assert!(quote_collateral_1 == user_1_end_quote, 0);
        assert!(     quote_total_1 == user_1_end_quote, 0);
        assert!( quote_available_1 == user_1_end_quote, 0);
        assert!( base_collateral_2 == user_2_end_base, 0);
        assert!(      base_total_2 == user_2_end_base, 0);
        assert!(  base_available_2 == user_2_end_base, 0);
        assert!(quote_collateral_2 == user_2_end_quote, 0);
        assert!(     quote_total_2 == user_2_end_quote, 0);
        assert!( quote_available_2 == user_2_end_quote, 0);
        assert!( base_collateral_3 == user_3_end_base, 0);
        assert!(      base_total_3 == user_3_end_base, 0);
        assert!(  base_available_3 == user_3_end_base, 0);
        assert!(quote_collateral_3 == user_3_end_quote, 0);
        assert!(     quote_total_3 == user_3_end_quote, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE -
            USER_3_BID_SIZE * USER_3_BID_PRICE, 0);
        // Assert user orders popped except for final user
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID, side, order_id_2), 0);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_3_order_base_parcels == USER_3_BID_SIZE -
            user_3_fill_size, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify post-fill state for user submitting market buy where the
    /// specified `max_quote_units` limits them to a partial fill.
    fun test_fill_market_order_partial_fill_quote_limiting(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = BUY; // define market order style
        let side =  ASK; // define side of book orders fill against
        let max_base_parcels = 1000; // define max base parcels to fill
        let max_quote_units = 11; // define max quote units if buy
        // Calculate number of base parcels filled
        let base_parcels_filled = max_quote_units / USER_1_ASK_PRICE;
        // Calculate number of base coins routed
        let base_routed = base_parcels_filled * SCALE_FACTOR;
        // Calculate number of quote coins routed
        let quote_routed = base_parcels_filled * USER_1_ASK_PRICE;
        assert!( // assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order id of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert order book state
        let (order_base_parcels_1, order_user_1, order_custodian_id_1) =
            order_fields_test<BC, QC, E1>(@econia, order_id_1, side);
        let (order_base_parcels_2, order_user_2, order_custodian_id_2) =
            order_fields_test<BC, QC, E1>(@econia, order_id_2, side);
        let (order_base_parcels_3, order_user_3, order_custodian_id_3) =
            order_fields_test<BC, QC, E1>(@econia, order_id_3, side);
        assert!(order_base_parcels_1 ==
            USER_1_ASK_SIZE - base_parcels_filled, 0);
        assert!(order_base_parcels_2 ==  USER_2_ASK_SIZE, 0);
        assert!(order_base_parcels_3 ==  USER_3_ASK_SIZE, 0);
        assert!(        order_user_1 == @user_1, 0);
        assert!(        order_user_2 == @user_2, 0);
        assert!(        order_user_3 == @user_3, 0);
        assert!(order_custodian_id_1 ==  USER_1_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_2 ==  USER_2_CUSTODIAN_ID, 0);
        assert!(order_custodian_id_3 ==  USER_3_CUSTODIAN_ID, 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) == order_id_1, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == USER_0_START_BASE + base_routed, 0);
        assert!(      base_total_0 == USER_0_START_BASE + base_routed, 0);
        assert!(  base_available_0 == USER_0_START_BASE + base_routed, 0);
        assert!(quote_collateral_0 == USER_0_START_QUOTE - quote_routed, 0);
        assert!(     quote_total_0 == USER_0_START_QUOTE - quote_routed, 0);
        assert!( quote_available_0 == USER_0_START_QUOTE - quote_routed, 0);
        assert!( base_collateral_1 == USER_1_START_BASE - base_routed, 0);
        assert!(      base_total_1 == USER_1_START_BASE - base_routed, 0);
        assert!(  base_available_1 == USER_1_START_BASE -
            USER_1_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_1 == USER_1_START_QUOTE + quote_routed, 0);
        assert!(     quote_total_1 == USER_1_START_QUOTE + quote_routed, 0);
        assert!( quote_available_1 == USER_1_START_QUOTE + quote_routed, 0);
        assert!( base_collateral_2 == USER_2_START_BASE, 0);
        assert!(      base_total_2 == USER_2_START_BASE, 0);
        assert!(  base_available_2 == USER_2_START_BASE -
            USER_2_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_2 == USER_2_START_QUOTE, 0);
        assert!(     quote_total_2 == USER_2_START_QUOTE, 0);
        assert!( quote_available_2 == USER_2_START_QUOTE, 0);
        assert!( base_collateral_3 == USER_3_START_BASE, 0);
        assert!(      base_total_3 == USER_3_START_BASE, 0);
        assert!(  base_available_3 == USER_3_START_BASE -
            USER_3_ASK_SIZE * SCALE_FACTOR, 0);
        assert!(quote_collateral_3 == USER_3_START_QUOTE, 0);
        assert!(     quote_total_3 == USER_3_START_QUOTE, 0);
        assert!( quote_available_3 == USER_3_START_QUOTE, 0);
        // Assert user order sizes
        let user_1_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_1,
                USER_1_CUSTODIAN_ID, side, order_id_1);
        let user_2_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_2,
                USER_2_CUSTODIAN_ID, side, order_id_2);
        let user_3_order_base_parcels =
            user::order_base_parcels_test<BC, QC, E1>(@user_3,
                USER_3_CUSTODIAN_ID, side, order_id_3);
        assert!(user_1_order_base_parcels ==
            USER_1_ASK_SIZE - base_parcels_filled, 0);
        assert!(user_2_order_base_parcels == USER_2_ASK_SIZE, 0);
        assert!(user_3_order_base_parcels == USER_3_ASK_SIZE, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify post-trade state for filling through all price levels and
    /// popping the final trade on the book, for filling against asks
    fun test_fill_market_order_pop_final_ask(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = BUY; // Define market order style
        let side =  ASK; // Define side of book orders fill against
        let max_base_parcels = (USER_1_ASK_SIZE + USER_2_ASK_SIZE +
            USER_3_ASK_SIZE) + 1; // Calculate max base parcels
        // Define max quote units if buy (limiting factor here)
        let max_quote_units =
            (USER_1_ASK_SIZE * USER_1_ASK_PRICE) +
            (USER_2_ASK_SIZE * USER_2_ASK_PRICE) +
            (USER_3_ASK_SIZE * USER_3_ASK_PRICE);
        // Define base/quoute coins routed for each order on book
        let user_1_base_routed  = USER_1_ASK_SIZE * SCALE_FACTOR;
        let user_1_quote_routed = USER_1_ASK_SIZE * USER_1_ASK_PRICE;
        let user_2_base_routed  = USER_2_ASK_SIZE * SCALE_FACTOR;
        let user_2_quote_routed = USER_2_ASK_SIZE * USER_2_ASK_PRICE;
        let user_3_base_routed  = USER_3_ASK_SIZE * SCALE_FACTOR;
        let user_3_quote_routed = USER_3_ASK_SIZE * USER_3_ASK_PRICE;
        // Calculate end coin amounts for each user
        let user_0_end_base = USER_0_START_BASE + (user_1_base_routed +
            user_2_base_routed + user_3_base_routed);
        let user_0_end_quote = USER_0_START_QUOTE - (user_1_quote_routed +
            user_2_quote_routed + user_3_quote_routed);
        let user_1_end_base  = USER_1_START_BASE  - user_1_base_routed;
        let user_1_end_quote = USER_1_START_QUOTE + user_1_quote_routed;
        let user_2_end_base  = USER_2_START_BASE  - user_2_base_routed;
        let user_2_end_quote = USER_2_START_QUOTE + user_2_quote_routed;
        let user_3_end_base  = USER_3_START_BASE  - user_3_base_routed;
        let user_3_end_quote = USER_3_START_QUOTE + user_3_quote_routed;
        assert!( // Assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Assert all orders on book
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_2), 0);
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_3), 0);
        // Assert users have orders registered
        assert!(user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        assert!(user::has_order_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID, side, order_id_2), 0);
        assert!(user::has_order_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID, side, order_id_3), 0);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert all orders taken off book
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_2), 0);
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_3), 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) ==
            MIN_ASK_DEFAULT, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == user_0_end_base, 0);
        assert!(      base_total_0 == user_0_end_base, 0);
        assert!(  base_available_0 == user_0_end_base, 0);
        assert!(quote_collateral_0 == user_0_end_quote, 0);
        assert!(     quote_total_0 == user_0_end_quote, 0);
        assert!( quote_available_0 == user_0_end_quote, 0);
        assert!( base_collateral_1 == user_1_end_base, 0);
        assert!(      base_total_1 == user_1_end_base, 0);
        assert!(  base_available_1 == user_1_end_base, 0);
        assert!(quote_collateral_1 == user_1_end_quote, 0);
        assert!(     quote_total_1 == user_1_end_quote, 0);
        assert!( quote_available_1 == user_1_end_quote, 0);
        assert!( base_collateral_2 == user_2_end_base, 0);
        assert!(      base_total_2 == user_2_end_base, 0);
        assert!(  base_available_2 == user_2_end_base, 0);
        assert!(quote_collateral_2 == user_2_end_quote, 0);
        assert!(     quote_total_2 == user_2_end_quote, 0);
        assert!( quote_available_2 == user_2_end_quote, 0);
        assert!( base_collateral_3 == user_3_end_base, 0);
        assert!(      base_total_3 == user_3_end_base, 0);
        assert!(  base_available_3 == user_3_end_base, 0);
        assert!(quote_collateral_3 == user_3_end_quote, 0);
        assert!(     quote_total_3 == user_3_end_quote, 0);
        assert!( quote_available_3 == user_3_end_quote, 0);
        // Assert user orders popped
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID, side, order_id_2), 0);
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID, side, order_id_3), 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify post-trade state for filling through all price levels and
    /// popping the final trade on the book, for filling against bids
    fun test_fill_market_order_pop_final_bid(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let style = SELL; // Define market order style
        let side =  BID; // Define side of book orders fill against
        let max_base_parcels = USER_1_BID_SIZE + USER_2_BID_SIZE +
            USER_3_BID_SIZE + 1; // Define max base parcels to fill
        let max_quote_units = 0; // Define max quote units if buy
        // Define base/quoute coins routed for each order on book
        let user_1_base_routed  = USER_1_BID_SIZE * SCALE_FACTOR;
        let user_1_quote_routed = USER_1_BID_SIZE * USER_1_BID_PRICE;
        let user_2_base_routed  = USER_2_BID_SIZE * SCALE_FACTOR;
        let user_2_quote_routed = USER_2_BID_SIZE * USER_2_BID_PRICE;
        let user_3_base_routed  = USER_3_BID_SIZE * SCALE_FACTOR;
        let user_3_quote_routed = USER_3_BID_SIZE * USER_3_BID_PRICE;
        // Calculate end coin amounts for each user
        let user_0_end_base = USER_0_START_BASE - (user_1_base_routed +
            user_2_base_routed + user_3_base_routed);
        let user_0_end_quote = USER_0_START_QUOTE + (user_1_quote_routed +
            user_2_quote_routed + user_3_quote_routed);
        let user_1_end_base  = USER_1_START_BASE  + user_1_base_routed;
        let user_1_end_quote = USER_1_START_QUOTE - user_1_quote_routed;
        let user_2_end_base  = USER_2_START_BASE  + user_2_base_routed;
        let user_2_end_quote = USER_2_START_QUOTE - user_2_quote_routed;
        let user_3_end_base  = USER_3_START_BASE  + user_3_base_routed;
        let user_3_end_quote = USER_3_START_QUOTE - user_3_quote_routed;
        assert!( // Assert style and side match
            style == SELL && side == BID || style == BUY && side == ASK, 0);
        // Initialize test market, storing order ID of limit orders
        let (order_id_1, order_id_2, order_id_3) = init_market_test(side,
            econia, user_0, user_1, user_2, user_3);
        // Assert all orders on book
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_2), 0);
        assert!(has_order_test<BC, QC, E1>(@econia, side, order_id_3), 0);
        // Assert users have orders registered
        assert!(user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        assert!(user::has_order_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID, side, order_id_2), 0);
        assert!(user::has_order_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID, side, order_id_3), 0);
        // Attempt market order fill
        fill_market_order_user<BC, QC, E1>(user_0, @econia, style,
            max_base_parcels, max_quote_units);
        // Assert all orders taken off book
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_1), 0);
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_2), 0);
        assert!(!has_order_test<BC, QC, E1>(@econia, side, order_id_3), 0);
        assert!(spread_maker_test<BC, QC, E1>(@econia, side) ==
            MAX_BID_DEFAULT, 0);
        // Assert user collateral amounts
        let ( base_collateral_0,  base_total_0,  base_available_0,
             quote_collateral_0, quote_total_0, quote_available_0) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_0, USER_0_CUSTODIAN_ID);
        let ( base_collateral_1,  base_total_1,  base_available_1,
             quote_collateral_1, quote_total_1, quote_available_1) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID);
        let ( base_collateral_2,  base_total_2,  base_available_2,
             quote_collateral_2, quote_total_2, quote_available_2) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID);
        let ( base_collateral_3,  base_total_3,  base_available_3,
             quote_collateral_3, quote_total_3, quote_available_3) =
            user::get_collateral_state_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID);
        assert!( base_collateral_0 == user_0_end_base, 0);
        assert!(      base_total_0 == user_0_end_base, 0);
        assert!(  base_available_0 == user_0_end_base, 0);
        assert!(quote_collateral_0 == user_0_end_quote, 0);
        assert!(     quote_total_0 == user_0_end_quote, 0);
        assert!( quote_available_0 == user_0_end_quote, 0);
        assert!( base_collateral_1 == user_1_end_base, 0);
        assert!(      base_total_1 == user_1_end_base, 0);
        assert!(  base_available_1 == user_1_end_base, 0);
        assert!(quote_collateral_1 == user_1_end_quote, 0);
        assert!(     quote_total_1 == user_1_end_quote, 0);
        assert!( quote_available_1 == user_1_end_quote, 0);
        assert!( base_collateral_2 == user_2_end_base, 0);
        assert!(      base_total_2 == user_2_end_base, 0);
        assert!(  base_available_2 == user_2_end_base, 0);
        assert!(quote_collateral_2 == user_2_end_quote, 0);
        assert!(     quote_total_2 == user_2_end_quote, 0);
        assert!( quote_available_2 == user_2_end_quote, 0);
        assert!( base_collateral_3 == user_3_end_base, 0);
        assert!(      base_total_3 == user_3_end_base, 0);
        assert!(  base_available_3 == user_3_end_base, 0);
        assert!(quote_collateral_3 == user_3_end_quote, 0);
        assert!(     quote_total_3 == user_3_end_quote, 0);
        assert!( quote_available_3 == user_3_end_quote, 0);
        // Assert user orders popped
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_1, USER_1_CUSTODIAN_ID, side, order_id_1), 0);
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_2, USER_2_CUSTODIAN_ID, side, order_id_2), 0);
        assert!(!user::has_order_test<BC, QC, E1>(
                @user_3, USER_3_CUSTODIAN_ID, side, order_id_3), 0);
    }

    #[test]
    fun test_sdk_hooks(): OrderBook<BC, QC, E1> {
        let order_book = OrderBook<BC, QC, E1>{
            scale_factor: 123,
            asks: critbit::empty(),
            bids: critbit::empty(),
            min_ask: 234,
            max_bid: 345,
            counter: 0,
        }; // Define mock order book
        // Get orders vectors from empty book
        let (asks, bids) = book_orders_sdk<BC, QC, E1>(&mut order_book);
        // Assert both vectors empty
        assert!(vector::is_empty(&asks) && vector::is_empty(&bids), 0);
        // Get price level vectors from empty book
        let (ask_levels, bid_levels) =
            book_price_levels_sdk<BC, QC, E1>(&mut order_book);
        assert!( // Assert both vectors empty
            vector::is_empty(&ask_levels) && vector::is_empty(&bid_levels), 0);
        // Define default order struct field values
        let (user, custodian_id) = (@user, NO_CUSTODIAN);
        // Define mock order parameters for a single ask, and two bids,
        // where second bid is different price level from first
        let ask_0_price = 12;
        let ask_0_base_parcels = 123;
        let ask_0_order_id = order_id::order_id(
            ask_0_price, get_serial_id<BC, QC, E1>(&mut order_book), ASK);
        let bid_0_price = 8;
        let bid_0_base_parcels = 234;
        let bid_0_order_id = order_id::order_id(
            bid_0_price, get_serial_id<BC, QC, E1>(&mut order_book), BID);
        let bid_1_price = 7;
        let bid_1_base_parcels = 345;
        let bid_1_order_id = order_id::order_id(
            bid_1_price, get_serial_id<BC, QC, E1>(&mut order_book), BID);
        // Insert all orders to tree
        critbit::insert(&mut order_book.asks, ask_0_order_id, Order{
            base_parcels: ask_0_base_parcels, user, custodian_id});
        critbit::insert(&mut order_book.bids, bid_0_order_id, Order{
            base_parcels: bid_0_base_parcels, user, custodian_id});
        critbit::insert(&mut order_book.bids, bid_1_order_id, Order{
            base_parcels: bid_1_base_parcels, user, custodian_id});
        // Get orders
        (asks, bids) = book_orders_sdk<BC, QC, E1>(&mut order_book);
        // Assert all state
        let     ask_0_ref = vector::borrow(&asks, 0);
        assert!(ask_0_ref.price        ==     ask_0_price       , 0);
        assert!(ask_0_ref.base_parcels ==     ask_0_base_parcels, 0);
        let     bid_0_ref = vector::borrow(&bids, 0);
        assert!(bid_0_ref.price        ==     bid_0_price       , 0);
        assert!(bid_0_ref.base_parcels ==     bid_0_base_parcels, 0);
        let     bid_1_ref = vector::borrow(&bids, 1);
        assert!(bid_1_ref.price        ==     bid_1_price       , 0);
        assert!(bid_1_ref.base_parcels ==     bid_1_base_parcels, 0);
        // Get price levels
        (ask_levels, bid_levels) =
            book_price_levels_sdk<BC, QC, E1>(&mut order_book);
        // Assert all state
        let ask_level_0_ref = vector::borrow(&ask_levels, 0);
        assert!(ask_level_0_ref.price        == ask_0_price,       0);
        assert!(ask_level_0_ref.base_parcels == ask_0_base_parcels, 0);
        let bid_level_0_ref = vector::borrow(&bid_levels, 0);
        assert!(bid_level_0_ref.price        == bid_0_price,       0);
        assert!(bid_level_0_ref.base_parcels == bid_0_base_parcels, 0);
        let bid_level_1_ref = vector::borrow(&bid_levels, 1);
        assert!(bid_level_1_ref.price        == bid_1_price,       0);
        assert!(bid_level_1_ref.base_parcels == bid_1_base_parcels, 0);
        // Insert to tree another ask in same price level as first
        let ask_1_price = ask_0_price;
        let ask_1_base_parcels = 789;
        let ask_1_order_id = order_id::order_id(
            ask_1_price, get_serial_id<BC, QC, E1>(&mut order_book), ASK);
        critbit::insert(&mut order_book.asks, ask_1_order_id, Order{
            base_parcels: ask_1_base_parcels, user, custodian_id});
        // Get asks
        let (asks, _bids) = book_orders_sdk<BC, QC, E1>(&mut order_book);
        // Assert all state
        let     ask_0_ref = vector::borrow(&asks, 0);
        assert!(ask_0_ref.price        ==     ask_0_price       , 0);
        assert!(ask_0_ref.base_parcels ==     ask_0_base_parcels, 0);
        let     ask_1_ref = vector::borrow(&asks, 1);
        assert!(ask_1_ref.price        ==     ask_1_price       , 0);
        assert!(ask_1_ref.base_parcels ==     ask_1_base_parcels, 0);
        // Get ask price levels
        let (ask_levels, _bid_levels) =
            book_price_levels_sdk<BC, QC, E1>(&mut order_book);
        // Assert all state
        let ask_level_0_ref = vector::borrow(&ask_levels, 0);
        assert!(ask_level_0_ref.price == ask_0_price, 0);
        assert!(ask_level_0_ref.base_parcels == ask_0_base_parcels +
            ask_1_base_parcels, 0);
        order_book // Return rather than unpack
    }

    #[test(econia = @econia)]
    #[expected_failure(abort_code = 4)]
    /// Verify failure for no such order book
    fun test_swap_no_book(
        econia: &signer,
    ) acquires EconiaCapabilityStore, OrderBook {
        coins::init_coin_types(econia); // Init coin types
        // Initialize trading coins
        let (base_coins, quote_coins) = (coin::zero<BC>(), coin::zero<QC>());
        // Attempt invalid swap
        swap<BC, QC, E1>(BUY, @econia, &mut base_coins, &mut quote_coins);
        // Burn base and quote coins
        coins::burn(base_coins); coins::burn(quote_coins);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify expected returns for simulated swap buys
    fun test_simulate_swap_sdk_buy(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let (style, side) = (BUY, ASK); // Define buying against asks
        // Initialize test market
        init_market_test(side, econia, user_0, user_1, user_2, user_3);
        // Borrow mutable reference to order book
        let order_book_ref_mut =
            borrow_global_mut<OrderBook<BC, QC, E1>>(@econia);
        let quote_coin_surplus = 1; // Declare surplus quote coins
        // Calculate quote coins required to fill book
        let quote_coins_required =
            (USER_1_ASK_SIZE * USER_1_ASK_PRICE) +
            (USER_2_ASK_SIZE * USER_2_ASK_PRICE) +
            (USER_3_ASK_SIZE * USER_3_ASK_PRICE);
        // Calculate base coins received
        let base_coins_received = SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE + USER_3_ASK_SIZE);
        // Calculate coins in for filling all orders
        let coins_in = quote_coins_required + quote_coin_surplus;
        // Simulate a swap
        let (coins_out, coins_in_left) =
            simulate_swap_sdk<BC, QC, E1>(order_book_ref_mut, style, coins_in);
        // Assert expected returns
        assert!(coins_out == base_coins_received, 0);
        assert!(coins_in_left == quote_coin_surplus, 0);
        // Set coins in to not enough quote coins for buying even one
        // base parcel off of the first order
        coins_in = USER_1_ASK_PRICE - 1;
        // Simulate a swap
        (coins_out, coins_in_left) =
            simulate_swap_sdk<BC, QC, E1>(order_book_ref_mut, style, coins_in);
        // Assert expected returns
        assert!(coins_out == 0, 0);
        assert!(coins_in_left == coins_in, 0);
        // Simulate a swap for no coins in
        (coins_out, coins_in_left) =
            simulate_swap_sdk<BC, QC, E1>(order_book_ref_mut, style, 0);
        // Assert expected returns
        assert!(coins_out == 0, 0);
        assert!(coins_in_left == 0, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify expected returns for simulated swap sells
    fun test_simulate_swap_sdk_sell(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        let (style, side) = (SELL, BID); // Define selling against bids
        // Initialize test market
        init_market_test(side, econia, user_0, user_1, user_2, user_3);
        // Borrow mutable reference to order book
        let order_book_ref_mut =
            borrow_global_mut<OrderBook<BC, QC, E1>>(@econia);
        // Calculate base coins required to exactly fill book
        let coins_in = SCALE_FACTOR *
            (USER_1_BID_SIZE + USER_2_BID_SIZE + USER_3_BID_SIZE);
        // Calculate quote coins received
        let coins_out_expected =
            (USER_1_BID_SIZE * USER_1_BID_PRICE) +
            (USER_2_BID_SIZE * USER_2_BID_PRICE) +
            (USER_3_BID_SIZE * USER_3_BID_PRICE);
        // Simulate a swap
        let (coins_out, coins_in_left) =
            simulate_swap_sdk<BC, QC, E1>(order_book_ref_mut, style, coins_in);
        // Assert expected returns
        assert!(coins_out == coins_out_expected, 0);
        assert!(coins_in_left == 0, 0);
        // Calculate new coins in as just 1 less than old coins in
        coins_in = coins_in - 1;
        // Calculate base parcels filled against user 3
        let base_parcels_filled_against_3 = (coins_in -
            SCALE_FACTOR * (USER_1_BID_SIZE + USER_2_BID_SIZE)) /
                SCALE_FACTOR;
        // Calculate number of base parcels filled
        let base_parcels_filled = (USER_1_BID_SIZE + USER_2_BID_SIZE +
            base_parcels_filled_against_3);
        // Calculate surplus base coins
        let surplus_base_coins = coins_in - base_parcels_filled * SCALE_FACTOR;
        // Simulate a swap
        // Calculate quote coins recieved
        coins_out_expected =
            (USER_1_BID_SIZE * USER_1_BID_PRICE) +
            (USER_2_BID_SIZE * USER_2_BID_PRICE) +
            (base_parcels_filled_against_3 * USER_3_BID_PRICE);
        (coins_out, coins_in_left) =
            simulate_swap_sdk<BC, QC, E1>(order_book_ref_mut, style, coins_in);
        // Assert expected returns
        assert!(coins_out == coins_out_expected, 0);
        assert!(coins_in_left == surplus_base_coins, 0);
        // Simulate a swap for no coins in
        (coins_out, coins_in_left) =
            simulate_swap_sdk<BC, QC, E1>(order_book_ref_mut, style, 0);
        // Assert expected returns
        assert!(coins_out == 0, 0);
        assert!(coins_in_left == 0, 0);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify correct post-swap coin values for a buy. Modeled off of
    /// comprehensive `test_fill_market_order...()` test series, with
    /// a partial fill against the third order.
    fun test_swap_success_buy(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        // Initialize test market
        init_market_test(ASK, econia, user_0, user_1, user_2, user_3);
        let base_coins = coin::zero<BC>(); // Do not need base coins
        // Calculate base parcels filled against user 3
        let user_3_fill_size = USER_3_ASK_SIZE - 2;
        // Calculate base coins bought
        let base_coins_bought = SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE + user_3_fill_size);
        let quote_coins_spent = // Calculate quote coins spent
            (USER_1_ASK_SIZE * USER_1_ASK_PRICE) +
            (USER_2_ASK_SIZE * USER_2_ASK_PRICE) +
            (user_3_fill_size * USER_3_ASK_PRICE);
        // Mint necessary quote coins
        let quote_coins = coins::mint<QC>(econia, quote_coins_spent);
        // Place a swap
        swap<BC, QC, E1>(BUY, @econia, &mut base_coins, &mut quote_coins);
        // Assert coin values
        assert!(coin::value(&quote_coins) == 0, 0);
        assert!(coin::value(&base_coins) == base_coins_bought, 0);
        // Burn base and quote coins
        coins::burn(base_coins); coin::destroy_zero(quote_coins);
    }

    #[test(
        econia = @econia,
        user_0 = @user_0,
        user_1 = @user_1,
        user_2 = @user_2,
        user_3 = @user_3
    )]
    /// Verify correct post-swap coin values for a sell. Modeled off of
    /// comprehensive `test_fill_market_order...()` test series, with
    /// a complete fill against the second order.
    fun test_swap_success_sell(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) acquires EconiaCapabilityStore, OrderBook {
        // Initialize test market
        init_market_test(BID, econia, user_0, user_1, user_2, user_3);
        // Calculate base coins bought
        let base_coins_sold = SCALE_FACTOR *
            (USER_1_BID_SIZE + USER_2_BID_SIZE);
        let quote_coins_received = // Calculate quote coins received
            (USER_1_BID_SIZE * USER_1_BID_PRICE) +
            (USER_2_BID_SIZE * USER_2_BID_PRICE);
        // Mint necessary base coins
        let base_coins = coins::mint<BC>(econia, base_coins_sold);
        // Do not need quote coins
        let quote_coins = coin::zero<QC>();
        // Place a swap
        swap<BC, QC, E1>(SELL, @econia, &mut base_coins, &mut quote_coins);
        // Assert coin values
        assert!(coin::value(&quote_coins) == quote_coins_received, 0);
        assert!(coin::value(&base_coins) == 0, 0);
        // Burn base and quote coins
        coin::destroy_zero(base_coins); coins::burn(quote_coins);
    }

    // Tests <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

}