require 'rubygems'
require 'bud'

# @abstract VoteCounterProtocol is the interface for vote counting.
# A vote counting protocol should subclass VoteCounterProtocol.
module VoteCounterProtocol
  state do
    # On the client side, tell the vote counter to start counting
    # votes for a specific ballot.
    # @param [Object] ballot_id the unique id of the ballot
    # @param [Number] num_votes the number of votes that will be cast
    # (this number will remain static throughout the vote)
    interface input, :begin_vote, [:ballot_id] => [:num_votes]

    # On the client side, send votes to be counted
    # @param [Object] ballot_id the unique id of the ballot
    # @param [Object] vote specific vote
    # @param [String] note any extra information to provide along with 
    # the vote
    interface input, :cast_vote, [:ballot_id, :vote, :note]

    # Returns the result of the vote once
    # @param [Object] ballot_id the unique id of the ballot
    # @param [Symbol] status status of the vote, :success, :fail, :error
    # @param [Object] result outcome of the vote, contents depend on 
    # :vote field of cast_vote input
    # @param [Array] votes an aggregate of all of the votes cast
    # @param [Array] notes an aggregate of all of the notes sent
    interface output, :result, [:ballot_id] => [:status, :result, 
                                                :votes, :notes]
  end
end

# RatioVoteCounter is an implementation of the VoteCounterProtocol in
# which a floating point ratio is provided to specify what ratio of
# the total number of votes is needed for a "winning" vote. Note: the
# calculation is rounded up, ex. votes_needed = ceil((ratio) *
# num_votes).
# @see RatioVoteCounter implements VoteCounterProtocol
module RatioVoteCounter
  include VoteCounterProtocol
  state do
    # On the client side, tell the vote counter what ratio to set.
    # This ratio must be set before the vote starts.
    # @param [Object] ballot_id the unique id of the ballot
    # @param [Number] ratio floating point number for 
    # the percentage of votes needed to "win"
    interface input, :ratio, [:ballot_id] => [:ratio]

    # Table to hold the set of active ballots. 
    # TODO?: Include status of the ballot, either 'in progress' or 
    # the result if completed.
    table :ongoing_ballots, [:ballot_id] => [:num_votes]
    
    # Table to hold the ratios associated with ballots. 
    # This table is needed due to the _Note_ below.
    table :ballot_ratios, ratio.schema

    # Table to hold votes received for ballots.
    table :votes_rcvd, cast_vote.schema

    # _Note_: It may be the case that there are ratios or votes for
    # ballot_ids that are not yet in :ongoing_ballots, and vice versa
    # due to network delay, so this information must be stored in tables.

    # Scratch to hold summary data for a ballot, including total number
    # of votes cast, an array of those votes, and an array of notes.
    scratch :vote_summary, [:ballot_id] => [:cnt, :votes, :notes]

    # Scratch to hold no of votes cast for each vote/response for a ballot.
    scratch :grouped_vote_counts, [:ballot_id, :vote, :cnt]

    # Scratch to hold completed ballot_ids and accumulated data.
    scratch :completed_ballots, [:ballot_id, :num_votes, :votes, :notes]

    # Scratch to hold the number of votes needed for a winner for a ballot.
    scratch :votes_needed, [:ballot_id] => [:num_votes]

    # Scratch to hold the winning vote of a completed ballot, if one exists.
    # _Note_: There can only be one winner for a ballot. 
    # Duplicate key error will be thrown
    # if ratio is set improperly such that there can be multiple winners. 
    # This constraint stems from the fact that the output interface result 
    # has [:ballot_id] as its key, indicating 
    # at most one winner per ballot_id.
    scratch :winning_vote, [:ballot_id] => [:vote]
    # TODO?: We could consider supporting multiple winners by grouping them
    # together in the :result column, but I would not suggest it.
  end

  
  bloom :debug do
    stdio <~ ongoing_ballots {|i| ["At #{budtime}, ongoing_ballots has #{i.inspect}"]}
    stdio <~ ballot_ratios {|i| ["At #{budtime}, ballot_ratios has #{i.inspect}"]}
    stdio <~ votes_rcvd {|i| ["At #{budtime}, votes_rcvd has #{i.inspect}"]}
    
    stdio <~ completed_ballots {|i| ["At #{budtime}, completed_ballots has #{i.inspect}"]}
    stdio <~ winning_vote {|i| ["At #{budtime}, winning_vote has #{i.inspect}"]}
    stdio <~ votes_needed {|i| ["At #{budtime}, votes_needed has #{i.inspect}"]}
  end


  # Add a ballot to :ongoing_ballots when it appears in :begin_vote
  # if the associated ballot_id does not already exist in :ongoing_ballots.
  bloom :add_ballot do 
    ongoing_ballots <+ begin_vote.notin(ongoing_ballots, 
                                        :ballot_id => :ballot_id)
  end

  # Add a ratio to :ballot_ratios when it appears in :ratio
  # if the associated :ballot_id does not already exist in :ballot_ratios.
  # This method should be overwritten by subclasses.
  bloom :add_ballot_ratio do
    ballot_ratios <+ ratio.notin(ballot_ratios, :ballot_id => :ballot_id)
  end

  # Accumulate votes (and associated notes) as they appear on :cast_vote.
  # _Note_: Logic enforcing the allowed number of votes per agent should
  # be handled before a vote is put onto :cast_vote.
  bloom :gather_votes do
    # Store incoming votes in votes_rcvd table.
    # BIG TODO: change votes_rcvd so you can have multiple votes with same :vote,:note
    # possibly with an extra field like the count.
    votes_rcvd <= cast_vote
    
    # Additional processing for usage in :process_data.
    # Summarize vote data for each :ballot_id at each timestep.
    vote_summary <= votes_rcvd.group([:ballot_id], count(:vote), 
                                     accum(:vote), accum(:note))
    
    # Calculate number of votes for each [:ballot_id, :vote] combination 
    # at each timestep.
    grouped_vote_counts <= votes_rcvd.group([:ballot_id, :vote], count)
  end

  # Check for completed ballots and whether or not they have winners. A 
  # ballot is completed when the expected number of votes has been received.
  bloom :process_data do
    # Put a ballot's data into completed_ballots if the count in 
    # vote_summary equals num_votes in ongoing_ballots for that ballot.
    completed_ballots <= (vote_summary * ongoing_ballots).pairs(:ballot_id => :ballot_id, :cnt => :num_votes) do |s, b|
      [b.ballot_id, b.num_votes, s.votes, s.notes]
    end
    
    # Process completed ballots to determine a winner (success) or 
    # not (failure).
    # Step 1: Calculate the number of votes needed for a completed_ballot 
    # to have a winner.
    votes_needed <= (completed_ballots * ballot_ratios).pairs(:ballot_id => :ballot_id) do |b, r|
      [b.ballot_id, (r.ratio * b.num_votes).ceil]
    end
    
    # Step 2: Check grouped_vote_counts for each completed ballot to 
    # see if there exists
    # a count that >= the votes_needed for that ballot. 
    # If there is, indicate success along with the result. 
    # If there is not, indicate failure with a nil result.
    winning_vote <= (votes_needed * grouped_vote_counts).pairs(:ballot_id => :ballot_id) do |vn, gc|
      # Return a winning result if we have one.
      if gc.cnt >= vn.num_votes
        [gc.ballot_id, gc.vote]
      end
    end

    # Step 3: Put the proper results onto output interface result for 
    # completed ballots.
    # There is a winner for a completed ballot if there is a winning_vote 
    # entry with a matching ballot_id. 
    # If there is no winning_vote entry, then there is was no winner.
    result <= (completed_ballots * winning_vote).outer do |b, v|
      if b.ballot_id == v.ballot_id
        [b.ballot_id, :success, v.vote, b.votes, b.notes]
      else
        [b.ballot_id, :fail, nil, b.votes, b.notes]
      end
    end
    
    # Step 4: Cleanup. Remove completed ballots from tables.
    ongoing_ballots <- (ongoing_ballots * completed_ballots).lefts(:ballot_id => :ballot_id)
    ballot_ratios <- (ballot_ratios * completed_ballots).lefts(:ballot_id => :ballot_id)
    votes_rcvd <- (votes_rcvd * completed_ballots).lefts(:ballot_id => :ballot_id)
  end
end

# UnanimousVoteCounter is a specific case of RatioVoteCounter, 
# where the ratio is 1.
# @see UnanimousVoteCounter extends RatioVoteCounter
module UnanimousVoteCounter
  include RatioVoteCounter

  # Bypass the :ratio interface completely and insert [:ballotid, 1]
  # into ballot_ratios whenever a new ballot is put onto
  # begin_vote. No need to check if ballot_id already exists in
  # ballot_ratios because ratio = 1 regardless.
  # @override
  bloom :add_ballot_ratio do
    ballot_ratios <+ begin_vote {|bv| [bv.ballot_id, 1]}
  end
end

# MajorityVoteCounter is an implementation of the VoteCounterProtocol,
# where the number of votes needed for a majority is floor(0.5 *
# num_members) + 1
# @see UnanimousVoteCounter extends RatioVoteCounter
module MajorityVoteCounter
  include RatioVoteCounter

  # Bypass the :ratio interface completely and insert [:ballotid, floor(0.5*num_members)+1]
  # into ballot_ratios whenever a new ballot is put onto begin_vote. No need
  # to check if ballot_id already exists in ballot_ratios because
  # ratio = the majority number always.
  # @override
  bloom :add_ballot_ratio do
    ballot_ratios <+ begin_vote {|bv| [bv.ballot_id, 0.51]}
  end
  
  # _TODO_Verify: Can I just implement majority as a ratio of ceil(0.51*num_members) or something.
  # It would be so much more convenient!
end