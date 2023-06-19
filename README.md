# General Staking Contracts

It's a monolithic stakingpool with a single asset to receive to stake and as rewards.

The client requested that a fixed APR is set. So here it is.

## What's different?

Honestly not much. Instead of distributing tokens based on shares, it distrutes tokens based on time and your deposit alone.

We can get away with a fixed APY since `Token A` is both the deposit and reward, and `Token A` is also the base amount to say that the APR is consistent.
