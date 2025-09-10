Postal.open = {}

local wait_for_update, open, process

local controller = (function()
	local controller
	return function()
		controller = controller or Postal.control.controller()
		return controller
	end
end)()

function wait_for_update(k)
	return controller().wait(function() return true end, k)
end

function Postal.open.start(isreturn,selected, callback)
	controller().wait(function()
		-- Detect if this is "get all" mode by checking if selected includes all mail indices
		local inbox_count = GetInboxNumItems()
		local is_get_all = (getn(selected) == inbox_count)
		if is_get_all and not isreturn then
			-- Check if selected array is [1,2,3,...,inbox_count]
			for i = 1, inbox_count do
				if selected[i] ~= i then
					is_get_all = false
					break
				end
			end
		end

		if is_get_all and not isreturn then
			-- Use backwards pauseless processing for "get all" mode
			process_get_all(callback)
		else
			-- Use original logic for selected items or return mail
			process(isreturn,selected, function()
				callback()
			end)
		end
	end)
end

function Postal.open.stop()
	controller().wait(function() end)
end

function process_get_all(callback)
	local function process_pass()
		local inbox_count = GetInboxNumItems()
		if inbox_count == 0 then
			return callback() -- No mail left
		end

		-- Create array of all positions, backwards (high to low)
		local positions = {}
		for i = inbox_count, 1, -1 do
			tinsert(positions, i)
		end

		local function process_next_position()
			if getn(positions) == 0 then
				-- Finished this pass, check if more non-COD mail remains
				local remaining_non_cod = count_non_cod_mail()
				if remaining_non_cod > 0 then
					-- More non-COD mail found, start another pass
					return process_pass()
				else
					-- No more non-COD mail, we're done
					return callback()
				end
			end

			local pos = tremove(positions, 1) -- Take next position (highest remaining)
			local current_inbox_count = GetInboxNumItems()

			if pos > current_inbox_count or pos <= 0 then
				-- Position no longer valid, skip to next
				return process_next_position()
			end

			-- Process this position using backwards pauseless logic
			open_backwards_pauseless(pos, current_inbox_count, function()
				return process_next_position()
			end)
		end

		process_next_position()
	end

	process_pass()
end

function count_non_cod_mail()
	local count = 0
	local inbox_count = GetInboxNumItems()
	for i = 1, inbox_count do
		local _, _, _, _, money, COD_amount, _, has_item = GetInboxHeaderInfo(i)
		if COD_amount == 0 and (has_item or money > 0) then
			count = count + 1
		end
	end
	return count
end

function open_backwards_pauseless(i, inbox_count, k, printed_message)
	wait_for_update(function()
		local current_inbox_count = GetInboxNumItems()
		if current_inbox_count < inbox_count then
			-- Mail auto-deleted
			return k()
		end

		local _, _, sender, subject, money, COD_amount, _, has_item = GetInboxHeaderInfo(i)

		if COD_amount > 0 then
			-- Skip COD mail
			return k()
		elseif has_item then
			local itm_name, _, itm_qty, _, _ = GetInboxItem(i)
			TakeInboxItem(i)
			if not printed_message and sender and itm_name then
				Postal:Print("Received from |cff00ff00"..sender.."|r: "..itm_name.." (x"..itm_qty..")", 1, 1, 0)
				printed_message = true
			end
			-- No wait - pauseless processing
			return open_backwards_pauseless(i, inbox_count, k, printed_message)
		elseif money > 0 then
			TakeInboxMoney(i)
			if not printed_message and sender and subject then
				local _,ix = strfind(subject, "Auction successful: ",1,true)
				local sub
				if ix then sub = strsub(subject,ix) end
				if ix
				  then Postal:Print("Sold"..sub..": "..money_str(money), 1, 1, 0)
				  else Postal:Print("Received from |cff00ff00"..sender.."|r: "..money_str(money), 1, 1, 0)
				end
				printed_message = true
			end
			-- No wait - pauseless processing
			return open_backwards_pauseless(i, inbox_count, k, printed_message)
		else
			-- Empty mail, complete
			return k()
		end
	end)
end

function process(isreturn,selected, k)
	if getn(selected) == 0 then
		return k()
	else
		local index = selected[1]
		local inbox_count = GetInboxNumItems()
		if isreturn then
			returnmail(index, inbox_count, function(skipped)
				tremove(selected, 1)
				if not skipped then
					for i, _ in ipairs(selected) do
						selected[i] = selected[i] - 1
					end
				end
				return process(isreturn,selected, k)
			end)
		else
			open(index, inbox_count, function(skipped)
				tremove(selected, 1)
				if not skipped then
					for i, _ in ipairs(selected) do
						selected[i] = selected[i] - 1
					end
				end
				return process(isreturn,selected, k)
			end)
		end
	end
end

function money_str(amount)
	local gold = floor(abs(amount / 10000))
	local silver = floor(abs(mod(amount / 100, 100)))
	local copper = floor(abs(mod(amount, 100)))
	if gold > 0 then
		return format("%d gold, %d silver, %d copper", gold, silver, copper)
	elseif silver > 0 then
		return format("%d silver, %d copper", silver, copper)
	else
		return format("%d copper", copper)
	end
end

function returnmail(i,inbox_count, k)
	wait_for_update(function()
		local _, _, sender, subject, money, _, _, has_item, _, was_returned = GetInboxHeaderInfo(i)

		if was_returned then
			Postal:Print("Mail from, |cff00ff00"..sender.."|r: "..subject..", can not be returned, it is a returned item.", 1, 1, 0)
			controller().wait(function() return GetInboxNumItems() < inbox_count end, function()
				return open(i, inbox_count, k)
			end)
		elseif has_item then
			local itm_name, _, itm_qty, _, _ = GetInboxItem(i)
			Postal:Print("Returning to |cff00ff00"..sender.."|r: "..itm_name.." (x"..itm_qty..")", 1, 1, 0)
			ReturnInboxItem(i)
			controller().wait(function() return not ({GetInboxHeaderInfo(i)})[8] or GetInboxNumItems() < inbox_count end, function()
				return open(i, inbox_count, k)
			end)
		elseif money > 0 then
			Postal:Print("Returning to |cff00ff00"..sender.."|r: "..money_str(money), 1, 1, 0)
			ReturnInboxItem(i)
			controller().wait(function() return ({GetInboxHeaderInfo(i)})[5] == 0 or GetInboxNumItems() < inbox_count end, function()
				return open(i, inbox_count, k)
			end)
		end
		controller().wait(function() return GetInboxNumItems() < inbox_count end, function()
			return open(i, inbox_count, k)
		end)
	end)
end

function open(i, inbox_count, k)
	wait_for_update(function()
		local _, _, sender, subject, money, COD_amount, _, has_item = GetInboxHeaderInfo(i)
        -- local ix

		-- if subject then
		-- 	_,ix = strfind(subject, "Auction successful: ",1,true)
		-- 	if ix then subject = strsub(subject,ix) end end

		if GetInboxNumItems() < inbox_count then
			return k(false)
		elseif COD_amount > 0 then
			return k(true)
		elseif has_item then
			local itm_name, _, itm_qty, _, _ = GetInboxItem(i)
			TakeInboxItem(i)
			Postal:Print("Received from |cff00ff00"..sender.."|r: "..itm_name.." (x"..itm_qty..")", 1, 1, 0)
			controller().wait(function() return not ({GetInboxHeaderInfo(i)})[8] or GetInboxNumItems() < inbox_count end, function()
				return open(i, inbox_count, k)
			end)
		elseif money > 0 then
			TakeInboxMoney(i)
			local _,ix = strfind(subject, "Auction successful: ",1,true)
			local sub
			if ix then sub = strsub(subject,ix) end
			if ix
			  then Postal:Print("Sold"..sub..": "..money_str(money), 1, 1, 0)
			  else Postal:Print("Received from |cff00ff00"..sender.."|r: "..money_str(money), 1, 1, 0)
			end
			controller().wait(function() return ({GetInboxHeaderInfo(i)})[5] == 0 or GetInboxNumItems() < inbox_count end, function()
				return open(i, inbox_count, k)
			end)
		else
			DeleteInboxItem(i)
			controller().wait(function() return GetInboxNumItems() < inbox_count end, function()
				return open(i, inbox_count, k)
			end)
		end
	end)
end