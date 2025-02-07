/*******************************************************************************

    Definitions of the name registry API implementation

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.node.Registry;

import agora.api.Registry;
import agora.common.Amount;
import agora.common.DNS;
import agora.common.Ensure;
import agora.common.ManagedDatabase;
import agora.common.Task;
import agora.common.Types;
import agora.consensus.data.Block;
import agora.consensus.data.UTXO;
import agora.consensus.data.ValidatorInfo;
import agora.consensus.Ledger;
import agora.crypto.Hash;
import agora.crypto.Key;
import agora.crypto.Schnorr: Signature;
import agora.network.DNSResolver;
import agora.network.Manager;
import agora.node.Config;
import agora.flash.api.FlashAPI;
import agora.serialization.Serializer;
import agora.stats.Registry;
import agora.stats.Utils;
import agora.utils.Log;

import std.algorithm;
import std.array : array, replace;
import std.conv;
import std.datetime;
import std.format;
import std.range;
import std.socket : InternetAddress, Internet6Address;
import std.string;

import core.time;

static import std.uni;

import d2sqlite3 : ResultRange;
import vibe.http.client;
import vibe.web.rest;

/// Service and protocol label format used for URI resource record name
private immutable string uri_service_label = "_agora._tcp.%s";

/// Implementation of `NameRegistryAPI` using associative arrays
public class NameRegistry: NameRegistryAPI
{
    /// Logger instance
    protected Logger log;

    ///
    protected RegistryConfig config;

    /// Indexes for `zones`
    private enum ZoneIndex
    {
        Realm = 0,
        Validator = 1,
        Flash = 2,
    }

    /// Zones of the registry
    private ZoneData[ZoneIndex.max + 1] zones;

    /// The domain for `realm`
    private Domain realm;

    /// The domain of `validators` zone
    private Domain validators;

    /// The domain of `flash` zone
    private Domain flash;

    ///
    private NodeLedger ledger;

    ///
    private Height validator_info_height;

    ///
    private ValidatorInfo[] validator_info;

    /// Client to forward GET query to if we don't have a local match
    private NameRegistryAPI client;

    /// Supported DNS query types
    private immutable QTYPE[] supported_query_types = [
        QTYPE.A, QTYPE.AAAA, QTYPE.CNAME, QTYPE.AXFR, QTYPE.ALL, QTYPE.SOA, QTYPE.NS,
        QTYPE.URI,
    ];

    ///
    public this (Domain realm, RegistryConfig config, NodeLedger ledger,
        ManagedDatabase cache_db, ITaskManager taskman, NetworkManager network)
    {
        assert(ledger !is null);
        assert(cache_db !is null);

        this.config = config;
        this.log = Logger(__MODULE__);

        this.ledger = ledger;

        this.realm = realm;
        this.validators = Domain.fromSafeString("validators." ~ realm.toString());
        this.flash = Domain.fromSafeString("flash." ~ realm.toString());

        this.zones = [
            ZoneData("realm", this.realm,
                this.config.realm, cache_db, log, taskman, network),
            ZoneData("validator", this.validators,
                this.config.validators, cache_db, log, taskman, network),
            ZoneData("flash",  this.flash,
                this.config.flash, cache_db, log, taskman, network)
        ];

        Utils.getCollectorRegistry().addCollector(&this.collectStats);
    }

    public void start ()
    {
        this.client = this.zones[0].netman.makeRegistryClient();
        foreach (ref zone; this.zones)
            zone.start();
    }

    /***************************************************************************

        Collect registry stats

        Params:
            collector = the Collector to collect the stats into

    ***************************************************************************/

    private void collectStats (Collector collector)
    {
        RegistryStats stats;
        stats.registry_validator_record_count = this.zones[ZoneIndex.Validator].count();
        stats.registry_flash_record_count = this.zones[ZoneIndex.Flash].count();
        collector.collect(stats);
    }

    /// Returns: throws if payload is not valid
    protected TYPE ensureValidPayload (in RegistryPayloadData payload,
        TypedPayload previous) @safe
    {
        // check if we received stale data
        if (previous != TypedPayload.init)
            ensure(previous.payload.seq <= payload.seq,
                "registry already has a more up-to-date version of the data");

        ensure(payload.addresses.length > 0,
                "Payload for '{}' should have addresses but have 0",
                payload.public_key);

        // Check that there's either one CNAME, or multiple IPs
        TYPE payload_type;
        foreach (idx, const ref addr; payload.addresses)
        {
            const this_type = addr.host.guessAddressType();
            ensure(this_type != TYPE.CNAME || payload.addresses.length == 1,
                    "Can only have one domain name (CNAME) for payload, not: {}",
                    payload);
            payload_type = this_type;
        }
        return payload_type;
    }

    /// Implementation of `NameRegistryAPI.getValidator`
    public override const(RegistryPayloadData) getValidator (PublicKey public_key)
    {
        TypedPayload payload = this.zones[ZoneIndex.Validator].getPayload(public_key);
        if (payload != TypedPayload.init)
        {
            log.trace("Successfull GET /validator: {} => {}", public_key, payload);
            return payload.payload;
        }
        log.trace("Unsuccessfull GET /validators: {}", public_key);
        return RegistryPayloadData.init;
    }

    /// Internal endpoint, mimics `getValidator` but forward the query if needed
    public final const(RegistryPayloadData) getValidatorInternal (in PublicKey key)
    {
        TypedPayload payload = this.zones[ZoneIndex.Validator].getPayload(key);
        if (payload != TypedPayload.init)
            return payload.payload;

        // If we're not caching, we're either primary or secondary.
        // If we're primary, there's obviously no upstream to ask.
        // If we're secondary, we ask the primary, we do not want other zone data
        // to get out of sync (e.g. the serial), so we only query,
        // never store.
        if (this.zones[ZoneIndex.Validator].type == ZoneType.primary)
            return RegistryPayloadData.init;

        // We might not have an upstream configured either
        if (this.client is null)
            return RegistryPayloadData.init;

        auto upstream = this.client.getValidator(key);
        if (upstream !is RegistryPayloadData.init &&
            this.zones[ZoneIndex.Validator].type == ZoneType.caching)
            this.registerValidator(upstream, Signature.init);
        return upstream;
    }

    /***************************************************************************

        Get all network addresses of all validators

        Returns:
            Network addresses of all validators

    ***************************************************************************/

    public auto validatorsAddresses ()
    {
        return this.zones[ZoneIndex.Validator].getAddresses();
    }

    /// Implementation of `NameRegistryAPI.postValidator`
    public override void postValidator (RegistryPayloadData data, Signature sig)
    {
        ensure(this.zones[ZoneIndex.Validator].type != ZoneType.caching,
            "Couldn't register, server is not authoritative for the zone");

        ensure(data.verify(sig), "Incorrect signature for payload");
        this.registerValidator(data, sig);
    }

    /// Similar to `postValidator`, but does not perform signature verification
    public void registerValidator (RegistryPayloadData data, Signature sig) @safe
    {
        TYPE payload_type = this.ensureValidPayload(data,
            this.zones[ZoneIndex.Validator].getPayload(data.public_key));

        if (this.zones[ZoneIndex.Validator].type == ZoneType.secondary)
        {
            assert(sig !is Signature.init, "Secondary registry cannot perform local registration");
            this.zones[ZoneIndex.Validator].redirect_register.postValidator(data, sig);
            return;
        }

        // Last step is to check the state of the chain
        auto last_height = this.ledger.height() + 1;
        if (last_height > this.validator_info_height || this.validator_info.length == 0)
        {
            this.validator_info = this.ledger.getValidators(last_height);
            this.validator_info_height = last_height;
        }
        const stake = this.getStake(data.public_key);
        ensure(stake !is Hash.init, "Couldn't find an existing stake to match this key");

        this.zones[ZoneIndex.Validator].updatePayload(TypedPayload(payload_type, data, stake));
        this.zones[ZoneIndex.Validator].updateSOA();
    }

    /// Get the stake for which a validator is registering
    private Hash getStake (in PublicKey public_key) @safe
    {
        auto validator_info = this.validator_info
            .find!(info => info.address == public_key);
        if (!validator_info.empty)
            return validator_info.front.utxo;

        foreach (st; this.ledger.getStakes())
            if (public_key == st.output.address())
                return st.hash;

        return Hash.init;
    }

    /// Implementation of `NameRegistryAPI.getFlashNode`
    public override const(RegistryPayloadData) getFlashNode (PublicKey public_key)
    {
        TypedPayload payload = this.zones[ZoneIndex.Flash].getPayload(public_key);
        if (payload != TypedPayload.init)
        {
            log.trace("Successfull GET /flash_node: {} => {}", public_key, payload);
            return payload.payload;
        }
        log.trace("Unsuccessfull GET /flash_node: {}", public_key);
        return RegistryPayloadData.init;
    }

    /// Implementation of `NameRegistryAPI.postFlashNode`
    public override void postFlashNode (RegistryPayloadData data, Signature sig, KnownChannel channel)
    {
        ensure(this.zones[ZoneIndex.Flash].type != ZoneType.caching,
            "Couldn't register, server is not authoritative for the zone");

        ensure(data.verify(sig), "Incorrect signature for payload");

        TYPE payload_type = this.ensureValidPayload(data,
            this.zones[ZoneIndex.Flash].getPayload(data.public_key));

        if (this.zones[ZoneIndex.Flash].type == ZoneType.secondary)
        {
            this.zones[ZoneIndex.Flash].redirect_register.postFlashNode(data, sig, channel);
            return;
        }

        auto range = this.ledger.getBlocksFrom(channel.height);
        ensure(!range.empty, "Channel is at height {} but local Ledger is at height {}",
               channel.height, this.ledger.height);
        if (auto err = channel.conf.isNotValidOpenReason(range.front.txs))
            ensure(0, "Channel is not valid or open: {}", err);

        // register data
        log.info("Registering network addresses: {} for Flash public key: {}", data.addresses,
            data.public_key);
        this.zones[ZoneIndex.Flash].updatePayload(TypedPayload(payload_type, data));
        this.zones[ZoneIndex.Flash].updateSOA();
    }

    /***************************************************************************

        Accepts a DNS message and returns an answer to it.

        The input message should contains a serie of questions,
        which the server will answer.
        Currently, only one registry can exists (it assumes authority),
        and recursion is not yet supported.

        Params:
          query = The query received by the server
          sender = A delegate that allows to send a `Message` to the client.
                   A server may send multiple `Message`s as a response to a
                   single query, e.g. when doing zone transfer.
          tcp = True if DNS is accessed through TCP

    ***************************************************************************/

    public void answerQuestions (
        in Message query, string peer, scope void delegate (in Message) @safe sender,
        bool tcp = false)
        @safe
    {
        Message reply;
        reply.header.RCODE = Header.RCode.FormatError;

        // EDNS(0) support
        // payloadSize must be treated to be at least 512. A payloadSize of 0
        // means no OPT record were found (there should be only one),
        // the requestor does not support EDNS0, and we should not include
        // an OPT record in our answer. It is only applicable for UDP.
        ushort payloadSize;
        if (!tcp)
        {
            foreach (const ref add; query.additionals)
            {
                if (add.type == TYPE.OPT)
                {
                    // This is a second OPT record, which is illegal by spec and
                    // triggers a FORMERR
                    if (payloadSize > 0)
                        goto BAILOUT;

                    scope opt = const(OPTRR)(add);
                    // 6.1.1: If an OPT record is present in a received request,
                    // compliant responders MUST include an OPT record in their
                    // respective responses.
                    OPTRR responseOPT;

                    if (opt.EDNSVersion() > 0)
                    {
                        responseOPT.extendedRCODE = 1; // BADVERS
                        reply.additionals ~= responseOPT.record;
                        goto BAILOUT;
                    }
                    // Ignore the DO bit for now
                    // `min` is to prevent DOS attack (request with huge payload size)
                    payloadSize = min(max(opt.payloadSize(), ushort(512)),
                        responseOPT.payloadSize());
                    reply.additionals ~= responseOPT.record;
                }
            }
            // No OPT record present, the client does not support EDNS
            if (payloadSize == 0)
                payloadSize = 512;
        }

        // Note: Since DNS has some fields which apply to the full response but
        // should actually be in `answers`, most resolvers will not ask unrelated
        // questions / will only ask one question at a time.
        foreach (const ref q; query.questions)
        {
            reply.questions ~= q;

            // RFC1034: 3.7.1. Standard queries
            // Since a particular name server may not know all of
            // the classes available in the domain system, it can never know if it is
            // authoritative for all classes. Hence responses to QCLASS=* queries can
            // never be authoritative.
            if (q.qclass == QCLASS.ANY)
                reply.header.AA = false;
            else if (q.qclass != QCLASS.IN)
            {
                log.warn("DNS: Ignoring query with unknown QCLASS: {}", q);
                reply.header.RCODE = Header.RCode.NotImplemented;
                break;
            }

            if (!supported_query_types.canFind(q.qtype))
            {
                log.warn("DNS: Ignoring query for unknown QTYPE: {}", q);
                reply.header.RCODE = Header.RCode.NotImplemented;
                break;
            }

            auto answer = this.findZone(q.qname);
            if (!answer)
            {
                log.warn("Refusing {} for unknown zone: {}", q.qtype, q.qname);
                reply.header.RCODE = Header.RCode.Refused;
                break;
            }

            reply.header.RCODE = answer(q, reply, peer);

            if (!tcp && reply.maxSerializedSize() > payloadSize)
            {
                reply.questions = reply.questions[0 .. $ - 1];
                reply.answers = reply.answers[0 .. $ - 1];
                reply.header.TC = true;
                break;
            }
        }

    BAILOUT:
        reply.fill(query.header);
        log.trace("{} DNS query: {} => {}",
                  (reply.header.RCODE == Header.RCode.NoError) ? "Fullfilled" : "Unsuccessfull",
                  query, reply);
        sender(reply);
    }

    /***************************************************************************

        Find zone in registry

        Params:
            name = Domain name of the zone to be found

        Returns:
            Function pointer of answer for the zone, `null` is returned when no
            zone can be found

    ***************************************************************************/

    auto findZone (Domain name, bool matches = true) @safe
    {
        foreach (i, const ref zone; this.zones)
            if (zone.root == name)
                return matches ?
                    &this.zones[i].answer_matches : &this.zones[i].answer_owns;

        auto range = name.value.splitter('.');

        const child = range.front;
        range.popFront();
        if (child.length < 1 || range.front.length < 1)
            return null;
        // Slice past the dot, after making sure there is one (bosagora/agora#2551)
        const parentDomain = Domain.fromSafeString(name.value[child.length + 1 .. $]);
        return this.findZone(parentDomain, false);
    }

    /***************************************************************************

        Callback for block creation

        Params:
          block = New block
          validators_changed = if the validator set has changed with this block

    ***************************************************************************/

    public void onAcceptedBlock (in Block, bool validators_changed)
        @safe
    {
        ZoneType validator_type = this.zones[ZoneIndex.Validator].type;

        if (this.zones[ZoneIndex.Validator].type == ZoneType.primary)
        {
            this.zones[ZoneIndex.Validator].each!((ResourceRecord[] rrs) {
                // That is not the performant way, until another approach this can
                // help us to go through URI records
                auto tpayload = this.zones[ZoneIndex.Validator].getPayload(
                    // Query in `opApply` guarantees that `rrs` cannot be empty
                    rrs[0].name.extractPublicKey()
                );
                if (this.ledger.getPenaltyDeposit(tpayload.utxo) == 0.coins)
                    this.zones[ZoneIndex.Validator].remove(tpayload.payload.public_key);
            });
        }
        else if (validator_type == ZoneType.secondary
                    && validators_changed)
        {
            // Even this manipulates the SOA timings, we can think it as a
            // NOTIFY request of the DNS, new node is found and zone needs update
            () @trusted {
                if (this.zones[ZoneIndex.Validator].soa_update_timer.pending)
                {
                    this.zones[ZoneIndex.Validator].soa_update_timer.stop;
                    this.zones[ZoneIndex.Validator].updateSOA();
                }
            } ();
        }
    }
}

/*******************************************************************************

    Parse a PublicKey from the a domain name

    Params:
      domain = The full domain name to parse

    Returns:
      A valid `PublicKey`, or `PublicKey.init`

*******************************************************************************/

private PublicKey extractPublicKey (in Domain domain) @safe
{
    // In the future, we may allow things like:
    // `admin.$PUBKEY.domain`, but for the moment, restrict it to
    // `$PUBKEY.domain`, and a public key is 63 chars with HRP,
    // 59 chars otherwise.
    enum PublicKeyStringLength = 63;
    enum NoHRPPublicKeyStringLength = 63 - "boa1".length;

    static PublicKey tryParse (in char[] data)
    {
        try return PublicKey.fromString(data);
        catch (Exception exc) return PublicKey.init;
    }

    auto splitted = domain.value.splitter('.');
    if (auto str = splitted.front)
    {
        // Check if `domain` includes service and protocol labels
        if (domain.serviceAndProtocolLabels() != Domain.ServiceProtoTuple.init)
        {
            splitted.popFront(); // Pop service
            splitted.popFront(); // Pop proto
            str = splitted.front;
        }

        if (str.length == PublicKeyStringLength)
            return tryParse(str);
        else if (str.length == NoHRPPublicKeyStringLength)
            return tryParse("boa1" ~ str);
        else
            return PublicKey.init;
    }
    return PublicKey.init;
}

// Check domain comparison
unittest
{
    import agora.utils.Test;

    const AStr = WK.Keys.A.address.toString();

    // Most likely case
    assert(extractPublicKey(Domain.fromString(AStr ~ ".net.bosagora.io")) ==
           WK.Keys.A.address);

    // Technically, request may end with the null label (a dot), and the user
    // might also specify it, so test for it.
    assert(extractPublicKey(Domain.fromString(AStr ~ ".net.bosagora.io.")) ==
           WK.Keys.A.address);

    // Without the HRP
    assert(extractPublicKey(Domain.fromString(AStr["boa1".length .. $] ~ ".net.bosagora.io")) ==
           WK.Keys.A.address);

    // Only gTLD
    assert(extractPublicKey(Domain.fromString(AStr ~ ".bosagora")) == WK.Keys.A.address);

    // Uppercase / lowercase doesn't matter, except for the key
    assert(extractPublicKey(Domain.fromString(AStr ~ ".BOSAGORA")) == WK.Keys.A.address);
    assert(extractPublicKey(Domain.fromString(AStr ~ ".BoSAGorA")) == WK.Keys.A.address);
    assert(extractPublicKey(Domain.fromString(AStr ~ ".BOSAGORA")) == WK.Keys.A.address);

    // Rejection tests
    assert(extractPublicKey(Domain.fromString(AStr[1 .. $] ~ ".boa")) is PublicKey.init);
    assert(extractPublicKey(Domain.fromString(AStr ~ ".bosagora")) == WK.Keys.A.address);

    // Uppercase / lowercase doesn't matter, except for the key
    assert(extractPublicKey(Domain.fromString(AStr ~ ".BOSAGORA")) == WK.Keys.A.address);
    assert(extractPublicKey(Domain.fromString(AStr ~ ".BoSAGorA")) == WK.Keys.A.address);
    assert(extractPublicKey(Domain.fromString(AStr ~ ".BOSAGORA")) == WK.Keys.A.address);

    // Rejection tests
    assert(extractPublicKey(Domain.fromString(AStr[1 .. $] ~ ".boa")) is PublicKey.init);
    auto invalid = AStr.dup;
    invalid[0] = 'c';
    assert(extractPublicKey(Domain.fromString(invalid ~ ".boa")) is PublicKey.init);
}

/// Converts a `ZoneConfig` to an `SOA` record
private SOA fromConfig (in ZoneConfig zone, Domain name) @safe
{
    return SOA(
        // mname, rname
        Domain.fromString(zone.primary), Domain.fromString(zone.soa.email.value.replace('@', '.')),
        cast(uint) Clock.currTime(UTC()).toUnixTime(),
        // Casts are safe as the values are validated during config parsing
        cast(int) zone.soa.refresh.total!"seconds",
        cast(int) zone.soa.retry.total!"seconds",
        cast(int) zone.soa.expire.total!"seconds",
        cast(uint) zone.soa.minimum.total!"seconds",
    );
}

/// Internal registry data
private struct TypedPayload
{
    /// The DNS RR TYPE
    public TYPE type;

    /// The payload itself
    public RegistryPayloadData payload;

    /// UTXO
    public Hash utxo;

    /***************************************************************************

        Make an instance of an `TypedPayload` from URI records

        Params:
            rr = DNS Resource record
            pubKeyParser = Delegate for parsing public key from RR domain

    ***************************************************************************/

    public static TypedPayload make (ResourceRecord[] rrs)
    {
        auto public_key = rrs[0].name.extractPublicKey();
        assert(public_key != PublicKey.init,
            "PublicKey cannot be extracted from domain");

        RegistryPayloadData reg_payload;
        reg_payload.public_key = public_key;
        reg_payload.ttl = rrs[0].ttl;

        foreach (rr; rrs)
            if (rr.type == TYPE.URI)
                reg_payload.addresses ~= rr.rdata.uri.target;

        ensure(reg_payload.addresses.length > 0,
            "Only URI records are supported to make TypedPayload");

        return TypedPayload(TYPE.URI, reg_payload, Hash.init);
    }

    /// Sink for writing ResourceRecord to a DNS Message buffer
    public alias ToRRDg = void delegate(ResourceRecord) @safe;

    /***************************************************************************

        Converts a `TypedPayload` to a valid `ResourceRecord`

        Params:
          name = The "question name", or the record name (e.g. in AXFR)
          dg = Writing delegate

        Throws:
          If the type of `this` payload is not supported, which would be
          a programming error.

    ***************************************************************************/

    public void toRR (const Domain name, scope ToRRDg dg) const scope
        @safe
    {
        switch (this.type)
        {
        case TYPE.CNAME:
            assert(this.payload.addresses.length == 1);
            // FIXME: Use a proper TTL

            /* If it's a CNAME, it has to be to another domain, as we don't
             * yet support aliases in the same zone, hence the algorithm in
             * "RFC1034: 4.3.2. Algorithm" can be reduced to "return the CNAME".
             */
            assert(this.payload.addresses.length == 1);
            dg(ResourceRecord.make!(TYPE.CNAME)(name, this.payload.ttl,
                Domain.fromString(this.payload.addresses[0].host)));

            // Add URI record along with
            dg(ResourceRecord.make!(TYPE.URI)(
                Domain.fromString(format(uri_service_label, name)),
                this.payload.ttl,
                this.payload.addresses[0],
            ));
            break;
        case TYPE.A: case TYPE.AAAA:
            foreach (idx, addr; this.payload.addresses)
            {
                const type = addr.host.guessAddressType();
                if (type == TYPE.A)
                {
                    auto iaddr = InternetAddress.parse(addr.host);
                    ensure(iaddr != InternetAddress.ADDR_NONE,
                        "DNS: Address '{}' (index: {}) is not an A record (record: {})",
                        addr, idx, this);

                    dg(ResourceRecord.make!(TYPE.A)(name, this.payload.ttl, iaddr));
                }
                else
                    dg(ResourceRecord.make!(TYPE.AAAA)(name, this.payload.ttl,
                        Internet6Address.parse(addr.host)));

                // Add URI record along with
                dg(ResourceRecord.make!(TYPE.URI)(
                    Domain.fromString(format(uri_service_label, name)),
                    this.payload.ttl,
                    addr,
                ));
            }
            break;
        default:
            ensure(0, "Unknown type: {} - {}", this.type, this);
            assert(0);
        }
    }
}

/// Type of a zone
private enum ZoneType
{
    /// When both `authoritative` and `SOA` configurations are set
    primary = 1,

    /// `authoritative` is set but `SOA` configuration is not
    secondary = 2,

    /// `authoritative` is not set
    caching = 3,
}

/// Contains infos related to either `validators` or `flash`
private struct ZoneData
{
    /// Type of the zone
    public ZoneType type = ZoneType.caching;

    /// Logger instance used by this zone
    private Logger log;

    /// The zone fully qualified name
    public Domain root;

    /// The SOA record
    public SOA soa;

    /// The NS record
    public ResourceRecord nsRecord;

    /// TTL of the SOA RR
    private uint soa_ttl;

    ///
    private ZoneConfig config;

    /// Query for registry count interface
    private string query_count;

    /// Query for getting all registries
    private string query_registry_get;

    /// Query for getting records
    private string query_records_get;

    /// Query for getting records with matching QTYPE
    private string query_records_get_typed;

    /// Query for getting registry utxo
    private string query_utxo_get;

    /// Query for adding registry utxo table
    private string query_utxo_add;

    /// Query for adding registry to addresses table
    private string query_addresses_add;

    /// Query for removing from registry utxo table
    private string query_utxo_remove;

    /// Query for getting all registered network addresses
    private string query_addresses_get;

    /// Query for clean up zone before AXFR, only for secondary zone
    private string query_axfr_cleanup;

    /// Query for clean up stale addresses before updating from primary
    private string query_stale_cleanup;

    /// Query for fetching records with expired TTLs
    private string query_ttl_expired;

    /// Query for getting next value for TTL timer
    private string query_ttl_timer;

    /// Database to store data
    private ManagedDatabase db;

    /// DNS resolver to send request, only for secondary and caching
    private DNSResolver resolver;

    /// Timer for requesting SOA from a primary to check serial, only for secondary
    private ITimer soa_update_timer;

    /// Timer for disabling zone when SOA check cannot be completed, only for secondary
    private ITimer expire_timer;

    /// Task manager to manage timers
    private ITaskManager taskman;

    /// REST API of a primary registry to redirect API calls, only for secondary
    private NameRegistryAPI redirect_register;

    private NetworkManager netman;

    /***************************************************************************

         Params:
           type_table_name = Registry table for table name
           cache_db = Database instance

    ***************************************************************************/

    public this (string zone_name, Domain root, ZoneConfig config,
        ManagedDatabase cache_db, Logger logger, ITaskManager taskman,
        NetworkManager network)
    {
        this.db = cache_db;
        this.log = logger;
        this.config = config;
        this.root = root;
        this.taskman = taskman;
        this.soa = SOA.init;
        this.netman = network;

        if (this.config.authoritative)
        {
            if (this.config.soa.email.set)
                this.type = ZoneType.primary;
            else
                this.type = ZoneType.secondary;
        }

        static string serverType (ZoneType zone_type)
        {
            switch (zone_type)
            {
                case ZoneType.primary: return "primary (authoritative)";
                case ZoneType.secondary: return "secondary (authoritative)";
                case ZoneType.caching: return "caching (non-authoritative)";
                default: return "Unsupported";
            }
        }

        this.log.info("Registry is {} DNS server for zone '{}'",
            serverType(this.type), this.root.value);

        if (this.config.primary.set)
            // FIXME: Make it a Domain in the config
            this.nsRecord = ResourceRecord.make!(TYPE.NS)(root, 600, Domain.fromString(this.config.primary.value));
        else
            this.nsRecord = ResourceRecord.init;

        this.query_count = format("SELECT COUNT(DISTINCT pubkey) FROM registry_%s_addresses",
            zone_name);

        this.query_registry_get = format("SELECT DISTINCT(pubkey) " ~
            "FROM registry_%s_addresses", zone_name);

        this.query_records_get = format("SELECT address, type, ttl " ~
            "FROM registry_%s_addresses WHERE pubkey = ?", zone_name);

        this.query_records_get_typed = format("SELECT address, type, ttl " ~
            "FROM registry_%s_addresses WHERE pubkey = ? AND type = ?", zone_name);

        this.query_utxo_get = format("SELECT sequence, utxo " ~
            "FROM registry_%s_utxo WHERE pubkey = ?", zone_name);

        this.query_utxo_add = format("REPLACE INTO registry_%s_utxo " ~
            "(pubkey, sequence, utxo) VALUES (?, ?, ?)", zone_name);

        this.query_addresses_add = format("REPLACE INTO registry_%s_addresses " ~
            "(pubkey, address, type, ttl, expires) VALUES (?, ?, ?, ?, ?)", zone_name);

        this.query_utxo_remove = format("DELETE FROM registry_%s_utxo WHERE pubkey = ?",
            zone_name);

        this.query_addresses_get = format("SELECT address " ~
            "FROM registry_%s_addresses WHERE type = 256", zone_name);

        this.query_axfr_cleanup = format("DELETE FROM registry_%s_addresses", zone_name);

        this.query_stale_cleanup = format("DELETE FROM registry_%s_addresses " ~
            "WHERE pubkey = ?", zone_name);

        this.query_ttl_expired = format("SELECT * FROM registry_%s_addresses " ~
            "WHERE expires <= ? ORDER BY expires ASC", zone_name);

        this.query_ttl_timer = format("SELECT expires FROM registry_%s_addresses " ~
                "ORDER BY expires ASC", zone_name);

        string query_sig_create = format("CREATE TABLE IF NOT EXISTS registry_%s_utxo " ~
            "(pubkey TEXT, sequence INTEGER NOT NULL, " ~
            "utxo TEXT NOT NULL, PRIMARY KEY(pubkey))", zone_name);

        string query_addr_create = format("CREATE TABLE IF NOT EXISTS registry_%s_addresses " ~
            "(pubkey TEXT, address TEXT NOT NULL, type INTEGER NOT NULL, " ~
            "ttl INTEGER NOT NULL, expires INTEGER, " ~
            "PRIMARY KEY(pubkey, address))", zone_name);

        // Creation of registry utxo table can be limited to only primary zones
        // after REST (GET) interface is disabled, it is created for all now
        // since caching registry uses this for adding payload to cache
        this.db.execute(query_sig_create);

        // Initialize common fields
        this.db.execute(query_addr_create);
        this.soa_ttl = 90;
    }

    /***************************************************************************

        Start the zone

    ***************************************************************************/

    public void start ()
    {
        if (this.type == ZoneType.primary)
            this.soa = this.config.fromConfig(this.root);
        else if (this.type == ZoneType.secondary
                || this.type == ZoneType.caching)
        {
            // DNS resolver is used to get SOA RR and performing AXFR
            auto peer_addrs = this.config.query_servers.map!(
                peer => Address("dns://" ~ peer)
            ).array();
            this.resolver = this.netman.makeDNSResolver(peer_addrs);

            if (this.type == ZoneType.secondary)
            {
                // Since a secondary zone cannot transfer UTXO, sequence and signature
                // fields of data from a primary, it redirects API calls to API of the
                // configured primary
                this.redirect_register = this.netman.makeRegistryClient(
                    Address(this.config.redirect_register));

                this.expire_timer = this.taskman.createTimer(&this.disable);
            }
            else
                this.expire_timer = this.taskman.createTimer(&this.updateTTLExpired);

            // Initialize timing fields with defaults in-case we couldn't reach
            // any primary to get our initial SOA record
            this.soa = SOA(Domain.init, Domain.init, 0, 540, 10, 6000, 120);
            this.soa_update_timer = this.taskman.setTimer(0.seconds, &this.updateSOA);
        }
    }

    /***************************************************************************

        Update the SOA RR of the zone

        Zone serial is set to current time when the zone is primary.
        If zone is secondary, SOA RR is requested from a configured primary and
        local SOA RR is updated accordingly. If new SOA RR has newer serial field
        AXFR transfer is initiated. SOA RR update is performed periodically
        according to the SOA RR's refresh field. SOA RR update period will be
        changed to the SOA RR's retry field and zone will be disabled after
        `EXPIRE` time when SOA RR request from primary fails.

        See also RFC 1034 - Section 4.3.5

        Caching zone will cache the SOA RR and will refresh the record according
        to the TTL value.

        Caching the SOA is allowed, see RFC 2181 - Section 7.2

    ***************************************************************************/

    public void updateSOA () @trusted
    {
        if (this.type == ZoneType.primary)
        {
            uint time = cast(uint) Clock.currTime(UTC()).toUnixTime();
            this.soa.serial = max(time, this.soa.serial + 1);
            return;
        }

        auto soa_answer = this.resolver.query(this.root.value, QTYPE.SOA);
        if (soa_answer.length != 1 || soa_answer[0].type != TYPE.SOA)
        {
            this.log.warn("{}: Couldn't get SOA record, will retry in {} seconds",
                this.root.value, this.soa.retry);

            this.soa_update_timer.rearm(this.soa.retry.seconds, false);
            if (this.type == ZoneType.secondary)
                this.expire_timer.rearm(this.soa.expire.seconds, false);

            return;
        }

        this.soa_ttl = soa_answer[0].ttl;
        SOA new_soa = soa_answer[0].rdata.soa;
        if (new_soa.serial > this.soa.serial)
        {
            this.soa = new_soa;
            if (this.type == ZoneType.secondary)
                this.axfrTransfer();
        }
        else
            this.log.trace("{}: Zone SOA is up-to-date", this.root.value);

        auto refresh = (this.type == ZoneType.secondary)
                        ? this.soa.refresh.seconds : this.soa_ttl.seconds;

        refresh = (refresh == 0.seconds) ? 90.seconds : refresh;

        this.soa_update_timer.rearm(refresh, false);

        if (this.type == ZoneType.secondary)
            this.expire_timer.stop();
    }

    /***************************************************************************

        Disable the zone

        A secondary zone is disabled when SOA serial cannot be checked for updates
        after `EXPIRE` amount of time. Zone is disabled by cleaning up all RRs.
        Thus, zone will return `NameError` to queries.

    ***************************************************************************/

    private void disable ()
    {
        // This will cause disabled zone to return NameError for queries
        this.db.execute(this.query_axfr_cleanup);
        this.log.warn("{}: Zone is disabled until one of primaries is reachable",
            this.root.value);
    }

    /***************************************************************************

        Update expired RRs of the caching zone

        Caching zone holds RRs with TTL values, records with TTL expired are
        updated from configured primary.

    ***************************************************************************/

    private void updateTTLExpired ()
    {
        auto time = cast(uint) Clock.currTime(UTC()).toUnixTime();
        auto expired_records = this.db.execute(this.query_ttl_expired, time);

        foreach (row; expired_records)
        {
            auto pubkey = PublicKey.fromString(row["pubkey"].as!string);
            auto qtype = row["type"].as!QTYPE;

            auto answer = this.resolver.query(
                        pubkey.toString ~ "." ~ this.root.value,
                        qtype
                        );

            if (!answer.length)
            {
                this.remove(pubkey);
                continue;
            }

            this.update(answer, time);
        }

        setTTLTimer();
    }

    /***************************************************************************

        Set-up TTL timer for next expiring Records

        Get next expiring record from the storage and setup timer to its
        expiring time.

    ***************************************************************************/

    private void setTTLTimer () @trusted
    {
        assert(this.type == ZoneType.caching,
            "TTL is only for caching zone");

        this.expire_timer.stop();

        auto expires_res = this.db.execute(this.query_ttl_timer);

        if (expires_res.empty())
            return;

        auto time = cast(uint) Clock.currTime(UTC()).toUnixTime();
        auto expires = expires_res.front["expires"].as!uint;
        this.expire_timer.rearm((expires - time).seconds, false);
    }

    /***************************************************************************

        Perform AXFR zone transfer

        A secondary server will transfer zone from primary when a zone update
        is detected.

    ***************************************************************************/

    private void axfrTransfer ()
    {
        ResourceRecord[] axfr_answer = this.resolver.query(this.root.value, QTYPE.AXFR);

        // We should answer with old Zone data until AXFR completes
        // since Agora is single threaded, there is nothing to do
        this.db.execute(this.query_axfr_cleanup);

        this.update(axfr_answer);
    }

    /***************************************************************************

         Returns:
           Total number of name registries

    ***************************************************************************/

    public ulong count () @trusted
    {
        auto results = this.db.execute(this.query_count);
        return results.empty ? 0 : results.oneValue!(ulong);
    }


    /***************************************************************************

        Iterates over all registered payloads

        This function supports iterating over all payload, allowing for zone
        transfer or any other zone-wide operation.

    ***************************************************************************/

    public int opApply (scope int delegate(ResourceRecord[]) dg) @trusted
    {
        auto query_results = this.db.execute(this.query_registry_get);

        foreach (row; query_results)
        {
            auto registry_pub_key = PublicKey.fromString(row["pubkey"].as!string);
            auto rrs = this.get(registry_pub_key);
            if (auto res = dg(rrs))
                return res;
        }

        return 0;
    }

    /***************************************************************************

         Answer a given question using this zone's data

         Returns:
          A code corresponding to the result of the query.
          `Header.RCode.Refused` is returned for the following conditions;
            - Query type is AXFR and query name is not matching with zone
            - Query type is not AXFR and query name is not owned by zone
            - Requesting peer is not whitelisted to perform AXFR

          Check `doAXFR` (AXFR queries) or `getKeyDNSRecord` (other queries)
          for other returns.

    ***************************************************************************/

    public Header.RCode answer (bool matches, in Question q, ref Message reply,
        string peer) @safe
    {
        reply.header.AA = (this.type != ZoneType.caching);
        reply.header.RA = (this.type == ZoneType.caching);

        if (q.qtype == QTYPE.AXFR)
            return matches
                    && this.config.allow_transfer.canFind(peer)
                    && this.type != ZoneType.caching
                    ? this.doAXFR(reply) : Header.RCode.Refused;
        else if (q.qtype == QTYPE.SOA)
        {
            if (matches)
                reply.answers ~= ResourceRecord.make!(TYPE.SOA)(this.root,
                    this.soa_ttl, this.soa);
            else
                reply.authorities ~= ResourceRecord.make!(TYPE.SOA)(this.root,
                    this.soa_ttl, this.soa);

            return Header.RCode.NoError;
        }
        else if (q.qtype == QTYPE.NS)
        {
            if (!matches)
                return Header.RCode.Refused;
            reply.answers ~= this.nsRecord;
            return Header.RCode.NoError;
        }
        else if (!matches)
        {
            auto rcode = this.getKeyDNSRecord(q, reply);
            if (rcode == Header.RCode.NameError
                && this.type == ZoneType.caching)
                    rcode = this.getAndCacheRecords(q, reply);

            return rcode;
        }
        else
            return Header.RCode.Refused;
    }

    /// Ditto
    public Header.RCode answer_matches (in Question q, ref Message reply,
        string peer) @safe
    {
        return this.answer(true, q, reply, peer);
    }

    /// Ditto
    public Header.RCode answer_owns (in Question q, ref Message reply,
        string peer) @safe
    {
        return this.answer(false, q, reply, peer);
    }

    /***************************************************************************

        Get and cache unknown record

        Caching zone start with empty storage and caches records through queries
        to itself from a configured primary. If a record could be found, it is
        cached and returned to the node that queried.

        Returns:
          A code corresponding to the result of the lookup.
          If the record could be found, `Header.RCode.NoError` is returned,
          `Header.RCode.NameError` is returned otherwise.

    ***************************************************************************/

    private Header.RCode getAndCacheRecords (const ref Question q, ref Message r)
    @trusted
    {
        this.log.trace("Caching records for query {}", q);
        auto answers = this.resolver.query(q.qname.value, q.qtype);

        if (!answers.length)
        {
            r.authorities ~= ResourceRecord.make!(TYPE.SOA)(
                                 this.root, this.soa_ttl, this.soa);
            return Header.RCode.NameError;
        }

        r.answers = answers;

        this.update(answers, cast(uint) Clock.currTime(UTC()).toUnixTime());

        setTTLTimer(); // DB updated, re-set timer to nearest expiring record
        return Header.RCode.NoError;
    }

    /***************************************************************************

        Perform AXFR for this zone

        Allow servers to synchronize with one another using this standard DNS
        query. Note that there are better ways to do synchronization,
        but AXFR was in the original specification.
        See RFC1034 "4.3.5. Zone maintenance and transfers".

        Params:
          reply = The `Message` to write to

    ***************************************************************************/

    private Header.RCode doAXFR (ref Message reply) @safe
    {
        log.info("Performing AXFR for {} ({} entries)", this.root.value, this.count());

        auto soa = ResourceRecord.make!(TYPE.SOA)(this.root, this.soa_ttl, this.soa);
        reply.answers ~= soa;

        foreach (rr; this)
            reply.answers ~= rr;

        reply.answers ~= soa;
        return Header.RCode.NoError;
    }

    /***************************************************************************

        Get a single key's DNS record.

        Queries sent to the server may attempt to look up multiple keys,
        which is handled by `answer`. This method looks up a single
        host name and return all associated addresses.

        Since we might have multiple addresses registered for a single key,
        we first attempt to find an IP address (`TYPE.A`) or IPv6 (`TYPE.AAAA`).
        If not, we return a `CNAME` (`TYPE.CNAME`).

        Params:
          question = The question being asked (contains the hostname)
          reply = A struct to fill the `answers` section with the addresses

        Returns:
          A code corresponding to the result of the lookup.
          If the lookup was successful, `Header.RCode.NoError` will be returned.
          Otherwise, the correct error code (non 0) is returned.

    ***************************************************************************/

    private Header.RCode getKeyDNSRecord (
        const ref Question question, ref Message reply) @safe
    {
        const public_key = question.qname.extractPublicKey();
        if (public_key is PublicKey.init)
            return Header.RCode.FormatError;

        auto answers = this.get(public_key, question.qtype);
        if (answers is null)
            return Header.RCode.NameError;

        // Caching zone is non-authoritative
        if (this.type != ZoneType.caching)
            reply.authorities ~= ResourceRecord.make!(TYPE.SOA)(
                                 this.root, this.soa_ttl, this.soa); // optional

        reply.answers = answers;

        return Header.RCode.NoError;
    }

    /***************************************************************************

         Get ResourceRecords from persistent storage

         Params:
           public_key = the public key that was used to register
                         the network addresses

           type = the type of the record that was requested, default is `ALL`

        Returns:
            ResourceRecord array with type `type` of name registry associated with
            `public_key`. All records for `public_key` are returned when `type`
            is `ALL`

    ***************************************************************************/

    public ResourceRecord[] get (PublicKey public_key, QTYPE type = QTYPE.ALL) @trusted
    {
        auto results = (type == QTYPE.ALL) ?
            this.db.execute(this.query_records_get, public_key)
            : this.db.execute(this.query_records_get_typed, public_key, type.to!ushort);

        if (results.empty && type != QTYPE.CNAME)
        {
            // RFC#1034 : Section 3.6.2
            // When a name server fails to find a desired RR in the resource set
            // associated with the domain name, it checks to see if the resource
            // set consists of a CNAME record with a matching class.
            results = this.db.execute(this.query_records_get_typed, public_key,
                QTYPE.CNAME.to!ushort);
        }

        if (results.empty)
            return null;

        const dname = Domain.fromString(format("%s.%s", public_key, this.root.value));
        return results.map!((r) {
            const type = to!TYPE(r["type"].as!ushort);
            const ttl =  r["ttl"].as!uint;
            const address = r["address"].as!string;
            switch (type)
            {
                case TYPE.A:
                    const addr = InternetAddress.parse(address);
                    ensure(addr != InternetAddress.ADDR_NONE, // TODO move this away
                       "DNS: Address '{}' is not an A record", addr);

                    return ResourceRecord.make!(TYPE.A)(
                        dname, ttl, addr
                    );
                case TYPE.AAAA:
                    const addr = Internet6Address.parse(address);
                    return ResourceRecord.make!(TYPE.AAAA)(
                        dname, ttl, addr
                    );
                case TYPE.CNAME:
                    return ResourceRecord.make!(TYPE.CNAME)(
                        dname, ttl, Domain.fromString(address)
                    );
                case TYPE.URI:
                    const url = Address(address);
                    return ResourceRecord.make!(TYPE.URI)(
                        Domain.fromString(format(uri_service_label, dname)),
                        ttl, url
                    );
                default:
                    assert(0);
            }
        }).array;
    }

    /***************************************************************************

         Get TypedPayload from persistent storage

         Params:
           public_key = the public key that was used to register
                         the network addresses

        Returns:
            TypedPayload including all URI addresses of `public_key`

    ***************************************************************************/

    public TypedPayload getPayload (PublicKey public_key) @trusted
    {
        auto records = this.get(public_key, QTYPE.URI);

        if (records.length == 0)
            return TypedPayload.init;

        auto payload = TypedPayload.make(records);

        if (this.type == ZoneType.primary)
        {
            auto result = this.db.execute(this.query_utxo_get, public_key);
            ensure(!result.empty, "empty result from getpayload");

            payload.payload.seq = result.front["sequence"].as!ulong;
            payload.utxo = Hash.fromString(result.front["utxo"].as!string);
        }

        return payload;
    }

    /***************************************************************************

        Returns:
          A range of URI record addresses contained in this zone

    ***************************************************************************/

    public auto getAddresses ()
    {
        auto results = this.db.execute(this.query_addresses_get);
        return results.map!(r => Address(r["address"].as!string));
    }

    /***************************************************************************

         Remove data from persistent storage

         Params:
           public_key = the public key that was used to register
                         the network addresses

    ***************************************************************************/

    public void remove (PublicKey public_key) @trusted
    {
        this.db.execute(this.query_stale_cleanup, public_key);
        this.db.execute(this.query_utxo_remove, public_key);

        if (this.db.changes)
            this.updateSOA();
    }

    /***************************************************************************

         Updates matching payload in the persistent storage. Payload is added
         to the persistent storage when no matching payload is found.
         This can only be called within a primary zone.

         Params:
           payload = Payload to update

    ***************************************************************************/

    public void updatePayload (TypedPayload payload) @trusted
    {
        if (payload.payload.addresses.length == 0)
            return;

        // Payload is equal to Zone's data, no need to update
        if (this.getPayload(payload.payload.public_key) == payload)
        {
            log.info("{} sent same payload data, zone is not updated",
                payload.payload.public_key);
            return;
        }

        log.info("Registering addresses {}: {} for public key: {}", payload.type,
            payload.payload.addresses, payload.payload.public_key);

        // Remove stale addrs
        db.execute(this.query_stale_cleanup, payload.payload.public_key);

        db.execute(this.query_utxo_add,
            payload.payload.public_key,
            payload.payload.seq,
            payload.utxo);

        ResourceRecord[] rrs;
        scope rranswer = (ResourceRecord rr) @safe {
            rrs ~= rr;
        };

        payload.toRR(Domain.fromString(format("%s.%s",
                payload.payload.public_key, this.root.value)), rranswer);

        this.update(rrs);
    }

    /***************************************************************************

         Updates matching records in the persistent storage. Records are added
         to the persistent storage when no matching records are found.

         Only records with type A, CNAME and URI is stored. If zone is caching,
         only records with TTL is stored.

         Params:
           rrs = ResourceRecords to update
           time = Current time, used during calculation for expiration time

    ***************************************************************************/

    public void update (ResourceRecord[] rrs, uint time = 0) @trusted
    {
        if (rrs is null)
            return;

        // There is no need to check for stale addresses
        // since `REPLACE INTO` is used and `DELETE` is cascaded.
        foreach (rr; rrs)
        {
            if (this.type == ZoneType.caching && rr.ttl <= 0)
                continue;

            string addr;

            switch (rr.type)
            {
                case TYPE.A:
                    import std.socket : InternetAddress;
                    auto arr_addr = rr.rdata.a;
                    scope in_addr = new InternetAddress(arr_addr,
                                        InternetAddress.PORT_ANY);
                    addr = in_addr.toAddrString();
                    break;
                case TYPE.AAAA:
                    import std.socket : Internet6Address;
                    scope in_addr = new Internet6Address(rr.rdata.aaaa,
                                        Internet6Address.PORT_ANY);
                    addr = in_addr.toAddrString();
                    break;
                case TYPE.CNAME:
                    addr = to!string(rr.rdata.name.value); // TODO
                    break;
                case TYPE.URI:
                    addr = rr.rdata.uri.target.toString();
                    break;
                case TYPE.SOA:
                    // SOA is not stored in permenant storage, see `soa`
                    continue;
                default:
                    assert(0, "RR type is not supported for permenant storage");
            }

            db.execute(this.query_addresses_add,
                rr.name.extractPublicKey(),
                addr,
                rr.type.to!ushort,
                rr.ttl,
                (time == 0) ? 0 : time + rr.ttl);
        }
    }
}
