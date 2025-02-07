/*******************************************************************************

    Contains tests for re-routing part of the frozen UTXO of a slashed
    validater to `CommonsBudget` address.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.test.SlashingMisbehavingValidator;

version (unittest):

import agora.crypto.Schnorr;
import agora.test.Base;

import core.atomic;
import core.stdc.stdint;
import core.thread;

/// Situation: A misbehaving validator does not reveal its preimages right after
///     it's enrolled.
/// Expectation: The information about the validator is stored in a block.
///     The validator is un-enrolled and a part of its fund is refunded to the
///     validators with the 10K of the fund going to the `CommonsBudget` address.
unittest
{
    static class BadAPIManager : TestAPIManager
    {
        public static shared bool reveal_preimage = false;

        ///
        mixin ForwardCtor!();

        ///
        public override void createNewNode (Config conf, string file, int line)
        {
            if (this.nodes.length == 5)
                this.addNewNode!NoPreImageVN(conf, &reveal_preimage, file, line);
            else
                super.createNewNode(conf, file, line);
        }
    }

    TestConf conf = {
        recurring_enrollment : false,
    };
    conf.consensus.payout_period = 3;
    auto network = makeTestNetwork!BadAPIManager(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();

    auto nodes = network.nodes;
    auto spendable = network.blocks[$ - 1].spendable().array;
    auto bad_address = nodes[5].getPublicKey().key;

    auto utxos = nodes[0].getUTXOs(bad_address);
    assert(nodes[0].getPenaltyDeposit(utxos[0].hash) != 0.coins);
    // block 1
    // Node index is 5 for bad node so we do not expect pre-image from it
    network.expectHeightAndPreImg(iota(0, 5), Height(1), network.blocks[0].header);

    assert(utxos.length == 1);
    auto block1 = nodes[0].getBlocksFrom(1, 1)[0];
    assert(block1.header.preimages.filter!(pi => pi is Hash.init).count() == 1);
    auto cnt = nodes[0].countActive(block1.header.height + 1);
    assert(cnt == 5, format!"Invalid validator count, current: %s"(cnt));

    // check if the frozen UTXO is still present but has no associated penalty deposit
    auto refund = nodes[0].getUTXOs(bad_address);
    assert(refund.length == 1);
    assert(utxos[0] == refund[0]);
    assert(nodes[0].getPenaltyDeposit(utxos[0].hash) == 0.coins);

    network.generateBlocks(iota(0, 5), Height(conf.consensus.payout_period * 3), true);
}

/// Situation: All the validators do not reveal their pre-images for
///     some time in the middle of creating the block of height 2 and
///     then start revealing their pre-images.
/// Expectation: The block of height 2 is created in the end after
///     some failures.
unittest
{
    TestConf conf = {
        recurring_enrollment : false,
    };
    auto network = makeTestNetwork!(LazyAPIManager!NoPreImageVN)(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();
    auto nodes = network.clients;
    auto txs = network.blocks[$ - 1].spendable().map!(txb => txb.sign()).array;

    // block 1 must not be created because all the validators do not
    // reveal any pre-images after their enrollments.
    txs.each!(tx => nodes[0].postTransaction(tx));
    Thread.sleep(2.seconds); // Give time before checking still height 0
    network.expectHeight(Height(0));

    // all the validators start revealing pre-images
    atomicStore(network.reveal_preimage, true);

    // block 1 was created with no slashed validator
    network.expectHeightAndPreImg(Height(1), network.blocks[0].header);
    auto block1 = nodes[0].getBlocksFrom(1, 1)[0];
    assert(block1.header.preimages.filter!(pi => pi is Hash.init).count() == 0);
}
