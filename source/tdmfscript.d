module tdmfscript;
import std.conv;
import std.file;
import std.format;
import std.stdio;
import std.string;
import std.utf;
import binread;
import binary.common;
import binary.writer;
import vibe.data.json;
import vibe.data.serialization;

///Stores Script Header information
struct TextHeader {
	uint text_amount;
	uint unk1; //Sometimes its 4, sometimes its 8
	uint header_size; //This might also be where the script text data starts
	uint script_section_size; //How big the script text is
	uint offset_strings;
	uint strings_section_size1;
	uint offset3; //String Flags?
	uint section_size2;
	uint offset4; //File flags?
	uint section_size3;
	uint offset5; //String offset offsets
	uint section_size4;
	uint unk3;
	uint offset6;
	uint offset7;
	uint unk4;
}

///Stores Specific Text Entry Info
struct TextInfo {
	//uint flags;
	wstring text_contents;
	bool hasEntryInOffsetOffsets; //Sometimes, the string offset offsets will not have an offset for a specific entry
	bool noTerminator;            //Sometimes, the text has no terminator
	@embedNullable uint manualOffset; //There are some funny files that have weird string offsets for some entries
	@embedNullable bool hasManualOffset;
}

///Stores any data about special attribute pairs
struct AttributePair {
	string attribute;
	uint value; //Purpose unknown
}

///Data only found in presumably old versions of the string offsets section
struct OldStringData {
	@embedNullable ushort oldUnkData;
	@embedNullable ushort oldIndex;
	@embedNullable uint oldUnkData2;
}

///Container for Version 2 String Offset data
struct V2StringOffsetData {
	uint string_offset;
	uint string_index;
	uint nexString_offset;
	uint nexString2_offset;
	ushort Unk1Data;
	ushort Unk2Data;
	uint Unk3Data;
}

///Stores general file attribute data
struct AttributeData {
	string[] attributeStrings;
	AttributePair[] attributePairs;
}

///Stores Text Script information
struct TextScript {
	TextHeader header;
	TextInfo[] text_info;
	@embedNullable OldStringData[] old_string_data;
	@embedNullable V2StringOffsetData[] v2_string_data;
	AttributeData attributes;
	uint[] flags;
	//string[] attributes;
	//string[] strings;
}

//This enum is to tokenize values that cannot be easily exported to JSON, primarily for byte accuracy
enum SpecialTokens : ushort
{
	uDEC0 = 57024,
}

///A handler for nexStringOffset, in which the process differs between versions
uint handler_nexStringOffset(File script, uint script_version)
{
	final switch(script_version)
	{
		case 1:
			if ((script.tell() & 15) == 8) //Avoid mangling nexStringOffset when we get close to oldData
			{
				readU32(script);
				readU32(script);
				return readU32(script);
			}
			goto case 3;
		case 3:
			return readU32(script);
	}
}

///A condensed extractor algorithm for Version 2 Scripts
void V2ScriptLoop(File script, TextScript* scriptInfo)
{
	//Obtain data from string offsets
	ulong[] offset_offsets;
	for(int i = 0; i < (scriptInfo.header.strings_section_size1 / 24); i++)
	{
		offset_offsets ~= script.tell();
		scriptInfo.v2_string_data ~= V2StringOffsetData(readU32(script), readU32(script),
			readU32(script), readU32(script), readU16(script), readU16(script), 
			readU32(script));
	}
	//Setup our offset table
	uint[] offset_table;
	for(int i = 0; i < scriptInfo.v2_string_data.length; i++)
	{
		offset_table ~= scriptInfo.v2_string_data[i].string_offset;
		offset_table ~= scriptInfo.v2_string_data[i].nexString_offset;
		offset_table ~= scriptInfo.v2_string_data[i].nexString2_offset;
	}
	//NOW we can extract the strings
	uint handledStrangeEntry = false; // set this to false first, then true every time we find a strange entry
	ulong curOffsetOffsetsPos = scriptInfo.header.offset5; //For holding our position in the string offset offsets section
	for(int i = 0; i < (offset_table.length - 1); i++)
	{
		uint curStringOffset = offset_table[i];
		writefln("offset_table[i]: %s", offset_table[i]);
		writefln("offset_table[i+1]: %s", offset_table[i+1]);
		//writefln("offset_table length: %s", offset_table.length);
		//ulong curStringOffsetPos = offset_offsets[i];
		uint nexStringOffset = offset_table[i+1];
		script.seek(curStringOffset); //Go to current string
		wstring str;
		uint bytesRead; //A metric for how many bytes for a string we've read
		while (true)
		{
			//Verify that our offset is NOT inside the header
			if (curStringOffset < 64)
			{
				//("Strange offset found, creating blank entry");
				str = ""; //Don't read anything, just make a blank entry
				handledStrangeEntry = true;
				break;
			}
			ushort char_ = readU16(script);
			ulong stringPos = script.tell; //Just in case our special token check messes up
			bytesRead += 2;
			//Is this short part of a string that can possibly be tokenized?
			if (char_ == SpecialTokens.uDEC0 && (readU16(script) == 0xB000))
			{
				//writeln("Found uDEC0 token, tokenizing...");
				str = "{{DEC0D0B000B0}}";
				break;
			}
			else
			{
				script.seek(stringPos);
			}
			//writefln("file offset: %s", script.tell());
			/*writeln(char_);*/
			if (char_ == 0) //Usually means EOL
			{
				break;
			}
			if (char_ == 1 || char_ == 2) //Special Identifier
			{
				wstring identifier = readUTF16Array(script, 1).assumeUTF;
				wstring other_number = readUTF16Array(script, 1).assumeUTF;//to!wstring(readU16(script));
				str ~= ("<" ~ to!wstring(char_) ~ identifier ~ other_number ~ ">"); //No spaces cause they USE spaces as a valid thing
				bytesRead += 4;
				continue;
			}
			if (char_ == 3) //ASCII?
			{
				str ~= ("{" ~ to!wstring(readU16(script)) ~ ", ");
				bytesRead += 2;
				while (true)
				{
					ubyte ascii_ = readU8(script);
					//writefln("Handled ASCII byte: %s", ascii_);
					bytesRead += 1;
					if (ascii_ == 0)
					{
						//Sometimes, there can be two 0s instead of one so check for that
						ulong curFileOffset = script.tell();
						//writefln("curFileOffset: %s", curFileOffset);
						//writefln("nexStringOffset: %s", cast(ulong)nexStringOffset - 2);
						//HACK: Report script position - 1 to offset check, this fixes ascii variables with an extra 0 nestled right next to the end of text entry
						if (readU8(script) == 0 && (script.tell() - 1) < cast(ulong)nexStringOffset - 2) //Second check is to make sure we aren't accidentally reading into the null terminator for the whole string
						{
							//writeln("Extra 0 needed");
							str ~= ", +}"; //Make sure to tell repacking code to add one extra 00
							bytesRead += 1;
							break;
						}
						//"No extra 0 needed"
						//writefln("curFileOffset: %s", script.tell());
						//writeln("No extra 0 needed");
						str ~= "}";
						script.seek(curFileOffset);
						break;
					}
					else
					{
						str ~= to!char(ascii_);
					}
				}
				continue;
			}
			ushort[] data;
			data ~= char_;
			//Hold on! Is this utf char valid?
			if (!isValidCodepoint(cast(wchar) char_))
			{
				//Assume we are reading a surrogate pair and unconditionally read another ushort
				//writeln("We aren't valid char yet! Assuming Surrogate Pair...");
				ushort low_surrogate = readU16(script);
				bytesRead += 2;
				uint newData;
				newData = char_<<16 | low_surrogate;//This is wacky
				uint[] newDataArr;
				newDataArr ~= newData;
				//writefln("New UTF: %08X", newData);
				//readln();
				if (!isValidCodepoint(to!dchar(newData))) //STILL not right???
				{
					//Lets just write both values as escape codes
					//writeln("STILL not valid, writing as individual escape codes");
					//This is dumb
					//ushort lh = newData & 0x0000FFFF;
					//ushort uh = newData & 0xFFFF;
					//writeln(low_surrogate);
					//writeln(char_);
					//readln();
					str ~= ("⟦" ~ to!wstring(format("%04X", char_)) ~ "⟧");
					// Sanity check to see if the UPPER half is also not valid
					if (!isValidCodepoint(to!wchar(low_surrogate)))
					{
						str ~= ("⟦" ~ to!wstring(format("%04X", low_surrogate)) ~ "⟧");
					}
					else
					{
						str ~= to!wchar(low_surrogate);
					}
				}
				else
				{
					str ~= cast(wstring)newDataArr.assumeUTF;
				}
				continue;
			}
			str ~= data.assumeUTF;
		}
		bool noTerminator = false;
		if (!handledStrangeEntry)
		{
			//Ok! All ready to add, but we need to make sure that we read the correct amount
			//writefln("Bytes Read: %s, Assumed Byte size of string: %s", bytesRead, nexStringOffset - curStringOffset);
			if (bytesRead > (nexStringOffset - curStringOffset))
			{
				//writeln("WARNING: We read more than supposed to! Redoing string...");
				noTerminator = true;
				str = "";
				ubyte[] secondPassString;
				script.seek(curStringOffset);//Jump back to start of string
				for (int j = 1; j <= (nexStringOffset - curStringOffset); j++)
				{
					secondPassString ~= readU8(script);
					if ((j % 2) == 0 && j != 0)
					{
						//writeln(("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[1]<<8 | secondPassString[0]))));
						//str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[j-1]<<8 | secondPassString[j-2]))); //What ???
						wchar codePoint = (secondPassString[1]<<8 | secondPassString[0]);
						if (!isValidCodepoint(codePoint)) //Probably surrogate
						{
							if ((codePoint >= 0xD800) | (codePoint <= 0xDBFF))
							{
								str ~= ("⟦" ~ to!wstring(format("%04X", codePoint)) ~ "⟧"); //Yes I'm using unicode to denote manual unicode
								//writeln("codePoint was surrogate pair");
								//writeln(str);
								//readln();
							}
							else
							{
								wchar newCodePoint = cast(wchar)(codePoint<<16 | readU16(script));
								if(!isValidCodepoint(newCodePoint))
								{
									ushort lh = newCodePoint & 0x0000FFFF;
									ushort uh = newCodePoint & 0xFFFF;
									str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", lh) ~ "\\" ~ "u" ~ format("%04X", uh));
									//writeln("newCodePoint invalid");
									//writeln(str);
									//readln();
								}
								else
								{
									str ~= newCodePoint;
									j += 2; //Got here? means we need to bump the for loop to account for the extra reading
									//writeln("newCodePoint valid");
									//writeln(str);
									//readln();
								}
							}
						}
						else
						{
							str ~= codePoint;
							//writeln("codePoint valid");
							//writeln(str);
							//readln();
						}
						secondPassString = [];
					}
				}
			}
			//Check if this entry's offset is inside the string offset offsets section
			script.seek(curOffsetOffsetsPos);
			uint validOffset = readU32(script);
			//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
			/*if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
			{
				scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false);
				curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
			}
			else
			{
				scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false);
			}*/
			scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false);
		}
		else
		{
			//Check if this entry's offset is inside the string offset offsets section
			script.seek(curOffsetOffsetsPos);
			uint validOffset = readU32(script);
			//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
			/*if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
			{
				scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false, curStringOffset, true); //Considering we had to manually set an offset...I dont think this path will be taken much
				curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
			}
			else
			{
				scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false, curStringOffset, true);
			}*/
			scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false, curStringOffset, true);
			handledStrangeEntry = false; //Reset this after we are done
		}
		//script.seek(stringOffsetIndex);
		writefln("Line %s at offset %s parsed.", i, curStringOffset);
	}
}

///Extracts Script Data, exporting it as an editable JSON format file
void extractScriptNew(File script, uint script_version)
{
	File jsonOut = File(script.name ~ ".json", "w"); //Output file
	TextScript scriptInfo;
	//*Read Header
	auto header = TextHeader(readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script));
	scriptInfo.header = header;
	ulong stringOffsetIndex;
	//*Begin Processing Text
	script.seek(header.offset_strings); //Go to string offset table
	uint handledStrangeEntry = false; // set this to false first, then true every time we find a strange entry
	ulong curOffsetOffsetsPos = header.offset5; //For holding our position in the string offset offsets section
	// Sometimes, we need a COMPLETELY different control loop for certain versions
	switch(script_version)
	{
		case 2:
			V2ScriptLoop(script, &scriptInfo);
			goto finish_extraction; //GOTO EWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW
		default:
			break;
	}
	for (int i = 0; i < (header.strings_section_size1 / 4); i++) 
	{
		ulong curStringOffsetPos = script.tell();
		uint curStringOffset = readU32(script);
		//Version 1 script files give us trouble with knowing when to stop reading.
		if (script_version == 1 && (curStringOffset > header.offset3 && (curStringOffsetPos & 15) != 8))
		{
			writeln("Tool has read all text data, but could not calculate line amount.");
			writeln("Press ENTER to complete extraction process.");
			readln();
			break;
		}
		stringOffsetIndex = script.tell();
		//Handle version differences related to nexStringOffset
		uint nexStringOffset = handler_nexStringOffset(script, script_version);
		ulong nexStringOffsetPos = script.tell();
		script.seek(curStringOffsetPos); // We'll be jumping off to somewhere else soon
		switch (script_version)
		{
			case 1: //Oldest version, String offset section is made of 2 uints of offsets and 2 ushorts, 1 uint of data
				if ((curStringOffsetPos & 15) == 8)
				{
					scriptInfo.old_string_data ~= OldStringData(readU16(script), readU16(script), readU32(script));
					//writefln("Current Offset: %s", script.tell());
					//readln();
				}
				else
				{
					goto case 3;
				}
				break;
			case 3:
				if (nexStringOffset < 0x40 && nexStringOffset != 0) //Don't accept a dumb offset as a value
				{
					script.seek(nexStringOffsetPos);
					nexStringOffset = readU32(script);
				} 
				else if (nexStringOffset == 0) // Usually means we are at the end of the string offsets section
				{
					script.seek(scriptInfo.header.offset4); // Use the script attributes offset since that is placed right after last text entry
					nexStringOffset = readU32(script);
				}
				goto default;
			default: //We use default as our string extracting case since all versions will eventually jump into this
				script.seek(curStringOffset); //Go to current string
				wstring str;
				uint bytesRead; //A metric for how many bytes for a string we've read
				while (true)
				{
					//Verify that our offset is NOT inside the header
					if (curStringOffset < 64)
					{
						//("Strange offset found, creating blank entry");
						str = ""; //Don't read anything, just make a blank entry
						handledStrangeEntry = true;
						break;
					}
					ushort char_ = readU16(script);
					ulong stringPos = script.tell; //Just in case our special token check messes up
					bytesRead += 2;
					//Is this short part of a string that can possibly be tokenized?
					if (char_ == SpecialTokens.uDEC0 && (readU16(script) == 0xB000))
					{
						//writeln("Found uDEC0 token, tokenizing...");
						str = "{{DEC0D0B000B0}}";
						break;
					}
					else
					{
						script.seek(stringPos);
					}
					//writefln("file offset: %s", script.tell());
					/*writeln(char_);*/
					if (char_ == 0) //Usually means EOL
					{
						break;
					}
					if (char_ == 1 || char_ == 2) //Special Identifier
					{
						wstring identifier = readUTF16Array(script, 1).assumeUTF;
						wstring other_number = readUTF16Array(script, 1).assumeUTF;//to!wstring(readU16(script));
						str ~= ("<" ~ to!wstring(char_) ~ identifier ~ other_number ~ ">"); //No spaces cause they USE spaces as a valid thing
						bytesRead += 4;
						continue;
					}
					if (char_ == 3) //ASCII?
					{
						str ~= ("{" ~ to!wstring(readU16(script)) ~ ", ");
						bytesRead += 2;
						while (true)
						{
							ubyte ascii_ = readU8(script);
							//writefln("Handled ASCII byte: %s", ascii_);
							bytesRead += 1;
							if (ascii_ == 0)
							{
								//Sometimes, there can be two 0s instead of one so check for that
								ulong curFileOffset = script.tell();
								//writefln("curFileOffset: %s", curFileOffset);
								//writefln("nexStringOffset: %s", cast(ulong)nexStringOffset - 2);
								//HACK: Report script position - 1 to offset check, this fixes ascii variables with an extra 0 nestled right next to the end of text entry
								if (readU8(script) == 0 && (script.tell() - 1) < cast(ulong)nexStringOffset - 2) //Second check is to make sure we aren't accidentally reading into the null terminator for the whole string
								{
									//writeln("Extra 0 needed");
									str ~= ", +}"; //Make sure to tell repacking code to add one extra 00
									bytesRead += 1;
									break;
								}
								//"No extra 0 needed"
								//writefln("curFileOffset: %s", script.tell());
								//writeln("No extra 0 needed");
								str ~= "}";
								script.seek(curFileOffset);
								break;
							}
							else
							{
								str ~= to!char(ascii_);
							}
						}
						continue;
					}
					ushort[] data;
					data ~= char_;
					//Hold on! Is this utf char valid?
					if (!isValidCodepoint(cast(wchar) char_))
					{
						//Assume we are reading a surrogate pair and unconditionally read another ushort
						//writeln("We aren't valid char yet! Assuming Surrogate Pair...");
						ushort low_surrogate = readU16(script);
						bytesRead += 2;
						uint newData;
						newData = char_<<16 | low_surrogate;//This is wacky
						uint[] newDataArr;
						newDataArr ~= newData;
						//writefln("New UTF: %08X", newData);
						//readln();
						if (!isValidCodepoint(to!dchar(newData))) //STILL not right???
						{
							//Lets just write both values as escape codes
							//writeln("STILL not valid, writing as individual escape codes");
							//This is dumb
							//ushort lh = newData & 0x0000FFFF;
							//ushort uh = newData & 0xFFFF;
							//writeln(low_surrogate);
							//writeln(char_);
							//readln();
							str ~= ("⟦" ~ to!wstring(format("%04X", char_)) ~ "⟧");
							// Sanity check to see if the UPPER half is also not valid
							if (!isValidCodepoint(to!wchar(low_surrogate)))
							{
								str ~= ("⟦" ~ to!wstring(format("%04X", low_surrogate)) ~ "⟧");
							}
							else
							{
								str ~= to!wchar(low_surrogate);
							}
						}
						else
						{
							str ~= cast(wstring)newDataArr.assumeUTF;
						}
						continue;
					}
					str ~= data.assumeUTF;
				}
				bool noTerminator = false;
				if (!handledStrangeEntry)
				{
					//Ok! All ready to add, but we need to make sure that we read the correct amount
					//writefln("Bytes Read: %s, Assumed Byte size of string: %s", bytesRead, nexStringOffset - curStringOffset);
					if (bytesRead > (nexStringOffset - curStringOffset))
					{
						//writeln("WARNING: We read more than supposed to! Redoing string...");
						noTerminator = true;
						str = "";
						ubyte[] secondPassString;
						script.seek(curStringOffset);//Jump back to start of string
						for (int j = 1; j <= (nexStringOffset - curStringOffset); j++)
						{
							secondPassString ~= readU8(script);
							if ((j % 2) == 0 && j != 0)
							{
								//writeln(("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[1]<<8 | secondPassString[0]))));
								//str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[j-1]<<8 | secondPassString[j-2]))); //What ???
								wchar codePoint = (secondPassString[1]<<8 | secondPassString[0]);
								if (!isValidCodepoint(codePoint)) //Probably surrogate
								{
									if ((codePoint >= 0xD800) | (codePoint <= 0xDBFF))
									{
										str ~= ("⟦" ~ to!wstring(format("%04X", codePoint)) ~ "⟧"); //Yes I'm using unicode to denote manual unicode
										//writeln("codePoint was surrogate pair");
										//writeln(str);
										//readln();
									}
									else
									{
										wchar newCodePoint = cast(wchar)(codePoint<<16 | readU16(script));
										if(!isValidCodepoint(newCodePoint))
										{
											ushort lh = newCodePoint & 0x0000FFFF;
											ushort uh = newCodePoint & 0xFFFF;
											str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", lh) ~ "\\" ~ "u" ~ format("%04X", uh));
											//writeln("newCodePoint invalid");
											//writeln(str);
											//readln();
										}
										else
										{
											str ~= newCodePoint;
											j += 2; //Got here? means we need to bump the for loop to account for the extra reading
											//writeln("newCodePoint valid");
											//writeln(str);
											//readln();
										}
									}
								}
								else
								{
									str ~= codePoint;
									//writeln("codePoint valid");
									//writeln(str);
									//readln();
								}
								secondPassString = [];
							}
						}
					}
					//Check if this entry's offset is inside the string offset offsets section
					script.seek(curOffsetOffsetsPos);
					uint validOffset = readU32(script);
					//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
					if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
					{
						scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false);
						curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
					}
					else
					{
						scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false);
					}
				}
				else
				{
					//Check if this entry's offset is inside the string offset offsets section
					script.seek(curOffsetOffsetsPos);
					uint validOffset = readU32(script);
					//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
					if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
					{
						scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false, curStringOffset, true); //Considering we had to manually set an offset...I dont think this path will be taken much
						curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
					}
					else
					{
						scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false, curStringOffset, true);
					}
					handledStrangeEntry = false; //Reset this after we are done
				}
				script.seek(stringOffsetIndex);
				writefln("Line %s at offset %s parsed.", i, curStringOffset);
		}
	}
finish_extraction: //LABLE EWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW
	/*Text(?) flags*/
	script.seek(scriptInfo.header.offset3);
	for (int i = 0; i < scriptInfo.header.section_size2; i += 4)
	{
		scriptInfo.flags ~= readU32(script);
	}
	/*Attributes*/
	script.seek(scriptInfo.header.offset4);
	script.seek(to!ulong(readU32(script)));
	string attribute;
	while (true)
	{
		ubyte ascii_ = readU8(script);
		if (ascii_ == 0)
		{
			//We check for a second 0 to determine if we reach the end of the list
			ulong curFileOffset = script.tell();
			if (readU8(script) == 0 || script.tell() >= scriptInfo.header.offset_strings) //Do not read into string offsets section
			{
				scriptInfo.attributes.attributeStrings ~= attribute;
				attribute = "";
				break;
			}
			script.seek(curFileOffset);
			scriptInfo.attributes.attributeStrings ~= attribute;
			attribute = "";
		}
		else
		{
			attribute ~= to!char(ascii_);
		}
	}
	//Now note down any special attribute pairs
	script.seek(scriptInfo.header.offset4);
	for (int i = 0; i < scriptInfo.header.section_size3; i += 8) //+8 because we are reading two bytes
	{
		ulong curPos = script.tell();
		script.seek(to!ulong(readU32(script))); //Jump to attribute name
		string attributeName;
		while (true) //Do this again because!!!!!!!!!!!!!!!
		{
			ubyte ascii_ = readU8(script);
			if (ascii_ == 0)
			{
				break;
			}
			else
			{
				attributeName ~= to!char(ascii_);
			}
		}
		//Seek back and read value
		script.seek(curPos+4);
		scriptInfo.attributes.attributePairs ~= AttributePair(attributeName, readU32(script));
	}
	/*Now we are all done!*/
	jsonOut.writeln(scriptInfo.serializeToPrettyJson);
}

///Extracts Script Data, exporting it as an editable JSON format
void extractScript(File script)
{
	File jsonOut = File(script.name ~ ".json", "w"); //Output file
	TextScript scriptInfo;
	//*Read Header
	auto header = TextHeader(readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script));
	scriptInfo.header = header;
	ulong stringOffsetIndex;
	//*Begin Processing Text
	script.seek(header.offset_strings); //Go to string offset table
	uint handledStrangeEntry = false; // set this to false first, then true every time we find a strange entry
	ulong curOffsetOffsetsPos = header.offset5; //For holding our position in the string offset offsets section
	for (int i = 0; i < (header.strings_section_size1 / 4); i++) 
	{
		ulong curStringOffsetPos = script.tell();
		uint curStringOffset = readU32(script);
		stringOffsetIndex = script.tell();
		uint nexStringOffset = readU32(script); // This will be useful to us when we verify byte length of strings
		if (nexStringOffset < 0x40 && nexStringOffset != 0) //Don't accept a dumb offset as a value
		{
			nexStringOffset = readU32(script);
		} 
		else if (nexStringOffset == 0) // Usually means we are at the end of the string offsets section
		{
			script.seek(scriptInfo.header.offset4); // Use the script attributes offset since that is placed right after last text entry
			nexStringOffset = readU32(script);
		}
		script.seek(curStringOffset); //Go to current string
		wstring str;
		uint bytesRead; //A metric for how many bytes for a string we've read
		while (true)
		{
			//Verify that our offset is NOT inside the header
			if (curStringOffset < 64)
			{
				//writeln("Strange offset found, creating blank entry");
				str = ""; //Don't read anything, just make a blank entry
				handledStrangeEntry = true;
				break;
			}
			ushort char_ = readU16(script);
			ulong stringPos = script.tell; //Just in case our special token check messes up
			bytesRead += 2;
			//Is this short part of a string that can possibly be tokenized?
			if (char_ == SpecialTokens.uDEC0 && (readU16(script) == 0xB000))
			{
				//writeln("Found uDEC0 token, tokenizing...");
				str = "{{DEC0D0B000B0}}";
				break;
			}
			else
			{
				script.seek(stringPos);
			}
			//writefln("file offset: %s", script.tell());
			/*writeln(char_);*/
			if (char_ == 0) //Usually means EOL
			{
				break;
			}
			if (char_ == 1 || char_ == 2) //Special Identifier
			{
				wstring identifier = readUTF16Array(script, 1).assumeUTF;
				wstring other_number = readUTF16Array(script, 1).assumeUTF;//to!wstring(readU16(script));
				str ~= ("<" ~ to!wstring(char_) ~ identifier ~ other_number ~ ">"); //No spaces cause they USE spaces as a valid thing
				bytesRead += 4;
				continue;
			}
			if (char_ == 3) //ASCII?
			{
				str ~= ("{" ~ to!wstring(readU16(script)) ~ ", ");
				bytesRead += 2;
				while (true)
				{
					ubyte ascii_ = readU8(script);
					//writefln("Handled ASCII byte: %s", ascii_);
					bytesRead += 1;
					if (ascii_ == 0)
					{
						//Sometimes, there can be two 0s instead of one so check for that
						ulong curFileOffset = script.tell();
						//writefln("curFileOffset: %s", curFileOffset);
						//writefln("nexStringOffset: %s", cast(ulong)nexStringOffset - 2);
						//HACK: Report script position - 1 to offset check, this fixes ascii variables with an extra 0 nestled right next to the end of text entry
						if (readU8(script) == 0 && (script.tell() - 1) < cast(ulong)nexStringOffset - 2) //Second check is to make sure we aren't accidentally reading into the null terminator for the whole string
						{
							//writeln("Extra 0 needed");
							str ~= ", +}"; //Make sure to tell repacking code to add one extra 00
							bytesRead += 1;
							break;
						}
						//"No extra 0 needed"
						//writefln("curFileOffset: %s", script.tell());
						//writeln("No extra 0 needed");
						str ~= "}";
						script.seek(curFileOffset);
						break;
					}
					else
					{
						str ~= to!char(ascii_);
					}
				}
				continue;
			}
			ushort[] data;
			data ~= char_;
			//Hold on! Is this utf char valid?
			if (!isValidCodepoint(cast(wchar) char_))
			{
				//Assume we are reading a surrogate pair and unconditionally read another ushort
				//writeln("We aren't valid char yet! Assuming Surrogate Pair...");
				ushort low_surrogate = readU16(script);
				bytesRead += 2;
				uint newData;
				newData = char_<<16 | low_surrogate;//This is wacky
				uint[] newDataArr;
				newDataArr ~= newData;
				//writefln("New UTF: %08X", newData);
				if (!isValidCodepoint(to!dchar(newData))) //STILL not right???
				{
					//Lets just write both values as escape codes
					//writeln("STILL not valid, writing as individual escape codes");
					//This is dumb
					//ushort lh = newData & 0x0000FFFF;
					//ushort uh = newData & 0xFFFF;
					//writeln(low_surrogate);
					//writeln(char_);
					//readln();
					str ~= ("⟦" ~ to!wstring(format("%04X", char_)) ~ "⟧");
					// Sanity check to see if the UPPER half is also not valid
					if (!isValidCodepoint(to!wchar(low_surrogate)))
					{
						str ~= ("⟦" ~ to!wstring(format("%04X", low_surrogate)) ~ "⟧");
					}
					else
					{
						str ~= to!wchar(low_surrogate);
					}
				}
				else
				{
					str ~= cast(wstring)newDataArr.assumeUTF;
				}
				continue;
			}
			str ~= data.assumeUTF;
			//writeln(str);
			//readln();
		}
		bool noTerminator = false;
		if (!handledStrangeEntry)
		{
			//Ok! All ready to add, but we need to make sure that we read the correct amount
			//writefln("Bytes Read: %s, Assumed Byte size of string: %s", bytesRead, nexStringOffset - curStringOffset);
			if (bytesRead > (nexStringOffset - curStringOffset))
			{
				//writeln("WARNING: We read more than supposed to! Redoing string...");
				noTerminator = true;
				str = "";
				ubyte[] secondPassString;
				script.seek(curStringOffset);//Jump back to start of string
				for (int j = 1; j <= (nexStringOffset - curStringOffset); j++)
				{
					secondPassString ~= readU8(script);
					if ((j % 2) == 0 && j != 0)
					{
						//writeln(("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[1]<<8 | secondPassString[0]))));
						//str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[j-1]<<8 | secondPassString[j-2]))); //What ???
						wchar codePoint = (secondPassString[1]<<8 | secondPassString[0]);
						if (!isValidCodepoint(codePoint)) //Probably surrogate
						{
							if ((codePoint >= 0xD800) | (codePoint <= 0xDBFF))
							{
								str ~= ("⟦" ~ to!wstring(format("%04X", codePoint)) ~ "⟧"); //Yes I'm using unicode to denote manual unicode
								//writeln("codePoint was surrogate pair");
								//writeln(str);
								//readln();
							}
							else
							{
								wchar newCodePoint = cast(wchar)(codePoint<<16 | readU16(script));
								if(!isValidCodepoint(newCodePoint))
								{
									ushort lh = newCodePoint & 0x0000FFFF;
									ushort uh = newCodePoint & 0xFFFF;
									str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", lh) ~ "\\" ~ "u" ~ format("%04X", uh));
									//writeln("newCodePoint invalid");
									//writeln(str);
									//readln();
								}
								else
								{
									str ~= newCodePoint;
									j += 2; //Got here? means we need to bump the for loop to account for the extra reading
									//writeln("newCodePoint valid");
									//writeln(str);
									//readln();
								}
							}
						}
						else
						{
							str ~= codePoint;
							//writeln("codePoint valid");
							//writeln(str);
							//readln();
						}
						secondPassString = [];
					}
				}
			}
			//Check if this entry's offset is inside the string offset offsets section
			script.seek(curOffsetOffsetsPos);
			uint validOffset = readU32(script);
			//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
			if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
			{
				scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false);
				curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
			}
			else
			{
				scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false);
			}
		}
		else
		{
			//Check if this entry's offset is inside the string offset offsets section
			script.seek(curOffsetOffsetsPos);
			uint validOffset = readU32(script);
			//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
			if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
			{
				scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false, curStringOffset, true); //Considering we had to manually set an offset...I dont think this path will be taken much
				curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
			}
			else
			{
				scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false, curStringOffset, true);
			}
			handledStrangeEntry = false; //Reset this after we are done
		}
		script.seek(stringOffsetIndex);
		writefln("Line %s at offset %s parsed.", i, curStringOffset);
	}
	/*Text(?) flags*/
	script.seek(scriptInfo.header.offset3);
	for (int i = 0; i < scriptInfo.header.section_size2; i += 4)
	{
		scriptInfo.flags ~= readU32(script);
	}
	/*Attributes*/
	script.seek(scriptInfo.header.offset4);
	script.seek(to!ulong(readU32(script)));
	string attribute;
	while (true)
	{
		ubyte ascii_ = readU8(script);
		if (ascii_ == 0)
		{
			//We check for a second 0 to determine if we reach the end of the list
			ulong curFileOffset = script.tell();
			if (readU8(script) == 0 || script.tell() >= scriptInfo.header.offset_strings) //Do not read into string offsets section
			{
				scriptInfo.attributes.attributeStrings ~= attribute;
				attribute = "";
				break;
			}
			script.seek(curFileOffset);
			scriptInfo.attributes.attributeStrings ~= attribute;
			attribute = "";
		}
		else
		{
			attribute ~= to!char(ascii_);
		}
	}
	//Now note down any special attribute pairs
	script.seek(scriptInfo.header.offset4);
	for (int i = 0; i < scriptInfo.header.section_size3; i += 8) //+8 because we are reading two bytes
	{
		ulong curPos = script.tell();
		script.seek(to!ulong(readU32(script))); //Jump to attribute name
		string attributeName;
		while (true) //Do this again because!!!!!!!!!!!!!!!
		{
			ubyte ascii_ = readU8(script);
			if (ascii_ == 0)
			{
				break;
			}
			else
			{
				attributeName ~= to!char(ascii_);
			}
		}
		//Seek back and read value
		script.seek(curPos+4);
		scriptInfo.attributes.attributePairs ~= AttributePair(attributeName, readU32(script));
	}
	/*Now we are all done!*/
	jsonOut.writeln(scriptInfo.serializeToPrettyJson);
}

//Some files have a completely different setup, so for now lets have a separate function to handle those.
void extractScriptOld(File script)
{
	File jsonOut = File(script.name ~ ".json", "w"); //Output file
	TextScript scriptInfo;
	//*Read Header
	auto header = TextHeader(readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script), readU32(script), 
		readU32(script), readU32(script));
	scriptInfo.header = header;
	ulong stringOffsetIndex;
	//*Begin Processing Text
	script.seek(header.offset_strings); //Go to string offset table
	uint handledStrangeEntry = false; // set this to false first, then true every time we find a strange entry
	ulong curOffsetOffsetsPos = header.offset5; //For holding our position in the string offset offsets section
	for (int i = 0; i < (header.strings_section_size1 / 4); i++) 
	{
		ulong curStringOffsetPos = script.tell();
		//writefln("Current Position: %s", curStringOffsetPos);
		//writefln("Current byte pos: %s", curStringOffsetPos & 15);
		uint curStringOffset = readU32(script);
		//writefln("curStringOffset: %s", curStringOffset);
		if (curStringOffset > header.offset3 && (curStringOffsetPos & 15) != 8)
		{
			writeln("Tool has read all text data, but could not calculate line amount.");
			writeln("Press ENTER to complete extraction process.");
			readln();
			break;
		}
		stringOffsetIndex = script.tell();
		uint nexStringOffset; // This will be useful to us when we verify byte length of strings
		if ((script.tell() & 15) == 8) //Avoid mangling nexStringOffset when we get close to oldData
		{
			readU32(script);
			readU32(script);
			nexStringOffset = readU32(script);
		}
		else
		{
			nexStringOffset = readU32(script);
		}
		ulong nexStringOffsetPos = script.tell();
		script.seek(curStringOffsetPos); // We'll be jumping off to somewhere else soon
		if ((curStringOffsetPos & 15) == 8)
		{
			scriptInfo.old_string_data ~= OldStringData(readU16(script), readU16(script), readU32(script));
			//writefln("Current Offset: %s", script.tell());
			//readln();
		}
		else
		{
			if (nexStringOffset < 0x40 && nexStringOffset != 0) //Don't accept a dumb offset as a value
			{
				script.seek(nexStringOffsetPos);
				nexStringOffset = readU32(script);
			} 
			else if (nexStringOffset == 0) // Usually means we are at the end of the string offsets section
			{
				script.seek(scriptInfo.header.offset4); // Use the script attributes offset since that is placed right after last text entry
				nexStringOffset = readU32(script);
			}
			script.seek(curStringOffset); //Go to current string
			wstring str;
			uint bytesRead; //A metric for how many bytes for a string we've read
			while (true)
			{
				//Verify that our offset is NOT inside the header
				if (curStringOffset < 64)
				{
					//("Strange offset found, creating blank entry");
					str = ""; //Don't read anything, just make a blank entry
					handledStrangeEntry = true;
					break;
				}
				ushort char_ = readU16(script);
				ulong stringPos = script.tell; //Just in case our special token check messes up
				bytesRead += 2;
				//Is this short part of a string that can possibly be tokenized?
				if (char_ == SpecialTokens.uDEC0 && (readU16(script) == 0xB000))
				{
					//writeln("Found uDEC0 token, tokenizing...");
					str = "{{DEC0D0B000B0}}";
					break;
				}
				else
				{
					script.seek(stringPos);
				}
				//writefln("file offset: %s", script.tell());
				/*writeln(char_);*/
				if (char_ == 0) //Usually means EOL
				{
					break;
				}
				if (char_ == 1 || char_ == 2) //Special Identifier
				{
					wstring identifier = readUTF16Array(script, 1).assumeUTF;
					wstring other_number = readUTF16Array(script, 1).assumeUTF;//to!wstring(readU16(script));
					str ~= ("<" ~ to!wstring(char_) ~ identifier ~ other_number ~ ">"); //No spaces cause they USE spaces as a valid thing
					bytesRead += 4;
					continue;
				}
				if (char_ == 3) //ASCII?
				{
					str ~= ("{" ~ to!wstring(readU16(script)) ~ ", ");
					bytesRead += 2;
					while (true)
					{
						ubyte ascii_ = readU8(script);
						//writefln("Handled ASCII byte: %s", ascii_);
						bytesRead += 1;
						if (ascii_ == 0)
						{
							//Sometimes, there can be two 0s instead of one so check for that
							ulong curFileOffset = script.tell();
							//writefln("curFileOffset: %s", curFileOffset);
							//writefln("nexStringOffset: %s", cast(ulong)nexStringOffset - 2);
							//HACK: Report script position - 1 to offset check, this fixes ascii variables with an extra 0 nestled right next to the end of text entry
							if (readU8(script) == 0 && (script.tell() - 1) < cast(ulong)nexStringOffset - 2) //Second check is to make sure we aren't accidentally reading into the null terminator for the whole string
							{
								//writeln("Extra 0 needed");
								str ~= ", +}"; //Make sure to tell repacking code to add one extra 00
								bytesRead += 1;
								break;
							}
							//"No extra 0 needed"
							//writefln("curFileOffset: %s", script.tell());
							//writeln("No extra 0 needed");
							str ~= "}";
							script.seek(curFileOffset);
							break;
						}
						else
						{
							str ~= to!char(ascii_);
						}
					}
					continue;
				}
				ushort[] data;
				data ~= char_;
				//Hold on! Is this utf char valid?
				if (!isValidCodepoint(cast(wchar) char_))
				{
					//Assume we are reading a surrogate pair and unconditionally read another ushort
					//writeln("We aren't valid char yet! Assuming Surrogate Pair...");
					ushort low_surrogate = readU16(script);
					bytesRead += 2;
					uint newData;
					newData = char_<<16 | low_surrogate;//This is wacky
					uint[] newDataArr;
					newDataArr ~= newData;
					//writefln("New UTF: %08X", newData);
					//readln();
					if (!isValidCodepoint(to!dchar(newData))) //STILL not right???
					{
						//Lets just write both values as escape codes
						//writeln("STILL not valid, writing as individual escape codes");
						//This is dumb
						//ushort lh = newData & 0x0000FFFF;
						//ushort uh = newData & 0xFFFF;
						//writeln(low_surrogate);
						//writeln(char_);
						//readln();
						str ~= ("⟦" ~ to!wstring(format("%04X", char_)) ~ "⟧");
						// Sanity check to see if the UPPER half is also not valid
						if (!isValidCodepoint(to!wchar(low_surrogate)))
						{
							str ~= ("⟦" ~ to!wstring(format("%04X", low_surrogate)) ~ "⟧");
						}
						else
						{
							str ~= to!wchar(low_surrogate);
						}
					}
					else
					{
						str ~= cast(wstring)newDataArr.assumeUTF;
					}
					continue;
				}
				str ~= data.assumeUTF;
			}
			bool noTerminator = false;
			if (!handledStrangeEntry)
			{
				//Ok! All ready to add, but we need to make sure that we read the correct amount
				//writefln("Bytes Read: %s, Assumed Byte size of string: %s", bytesRead, nexStringOffset - curStringOffset);
				if (bytesRead > (nexStringOffset - curStringOffset))
				{
					writeln("WARNING: We read more than supposed to! Redoing string...");
					noTerminator = true;
					str = "";
					ubyte[] secondPassString;
					script.seek(curStringOffset);//Jump back to start of string
					for (int j = 1; j <= (nexStringOffset - curStringOffset); j++)
					{
						secondPassString ~= readU8(script);
						if ((j % 2) == 0 && j != 0)
						{
							//writeln(("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[1]<<8 | secondPassString[0]))));
							//str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", cast(ushort)(secondPassString[j-1]<<8 | secondPassString[j-2]))); //What ???
							wchar codePoint = (secondPassString[1]<<8 | secondPassString[0]);
							if (!isValidCodepoint(codePoint)) //Probably surrogate
							{
								if ((codePoint >= 0xD800) | (codePoint <= 0xDBFF))
								{
									str ~= ("⟦" ~ to!wstring(format("%04X", codePoint)) ~ "⟧"); //Yes I'm using unicode to denote manual unicode
									//writeln("codePoint was surrogate pair");
									//writeln(str);
									//readln();
								}
								else
								{
									wchar newCodePoint = cast(wchar)(codePoint<<16 | readU16(script));
									if(!isValidCodepoint(newCodePoint))
									{
										ushort lh = newCodePoint & 0x0000FFFF;
										ushort uh = newCodePoint & 0xFFFF;
										str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", lh) ~ "\\" ~ "u" ~ format("%04X", uh));
										//writeln("newCodePoint invalid");
										//writeln(str);
										//readln();
									}
									else
									{
										str ~= newCodePoint;
										j += 2; //Got here? means we need to bump the for loop to account for the extra reading
										//writeln("newCodePoint valid");
										//writeln(str);
										//readln();
									}
								}
							}
							else
							{
								str ~= codePoint;
								//writeln("codePoint valid");
								//writeln(str);
								//readln();
							}
							secondPassString = [];
						}
					}
				}
				//Check if this entry's offset is inside the string offset offsets section
				script.seek(curOffsetOffsetsPos);
				uint validOffset = readU32(script);
				//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
				if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
				{
					scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false);
					curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
				}
				else
				{
					scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false);
				}
			}
			else
			{
				//Check if this entry's offset is inside the string offset offsets section
				script.seek(curOffsetOffsetsPos);
				uint validOffset = readU32(script);
				//writefln("validOffset: %s, curStringOffsetPos: %s", validOffset, curStringOffsetPos);
				if (validOffset == curStringOffsetPos) //Is our position in the string offsets RIGHT NOW something valid in the string offsets table?
				{
					scriptInfo.text_info ~= TextInfo(str, true, noTerminator ? true : false, curStringOffset, true); //Considering we had to manually set an offset...I dont think this path will be taken much
					curOffsetOffsetsPos = script.tell(); //Only move this forward in the table when its true
				}
				else
				{
					scriptInfo.text_info ~= TextInfo(str, false, noTerminator ? true : false, curStringOffset, true);
				}
				handledStrangeEntry = false; //Reset this after we are done
			}
			script.seek(stringOffsetIndex);
			writefln("Line %s at offset %s parsed.", i, curStringOffset);
		}
	}
	/*Text(?) flags*/
	script.seek(scriptInfo.header.offset3);
	for (int i = 0; i < scriptInfo.header.section_size2; i += 4)
	{
		scriptInfo.flags ~= readU32(script);
	}
	/*Attributes*/
	script.seek(scriptInfo.header.offset4);
	script.seek(to!ulong(readU32(script)));
	string attribute;
	while (true)
	{
		ubyte ascii_ = readU8(script);
		if (ascii_ == 0)
		{
			//We check for a second 0 to determine if we reach the end of the list
			ulong curFileOffset = script.tell();
			if (readU8(script) == 0 || script.tell() >= scriptInfo.header.offset_strings) //Do not read into string offsets section
			{
				scriptInfo.attributes.attributeStrings ~= attribute;
				attribute = "";
				break;
			}
			script.seek(curFileOffset);
			scriptInfo.attributes.attributeStrings ~= attribute;
			attribute = "";
		}
		else
		{
			attribute ~= to!char(ascii_);
		}
	}
	//Now note down any special attribute pairs
	script.seek(scriptInfo.header.offset4);
	for (int i = 0; i < scriptInfo.header.section_size3; i += 8) //+8 because we are reading two bytes
	{
		ulong curPos = script.tell();
		script.seek(to!ulong(readU32(script))); //Jump to attribute name
		string attributeName;
		while (true) //Do this again because!!!!!!!!!!!!!!!
		{
			ubyte ascii_ = readU8(script);
			if (ascii_ == 0)
			{
				break;
			}
			else
			{
				attributeName ~= to!char(ascii_);
			}
		}
		//Seek back and read value
		script.seek(curPos+4);
		scriptInfo.attributes.attributePairs ~= AttributePair(attributeName, readU32(script));
	}
	/*Now we are all done!*/
	jsonOut.writeln(scriptInfo.serializeToPrettyJson);
}

void repackScriptNew(File json, uint script_version)
{
    const string jsonData = readText(json.name);
    const Json jsonInfo = parseJsonString(jsonData);
    TextScript textScript = deserializeJson!TextScript(jsonInfo);
    BinaryWriter writer = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter textContent = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter stringOffsets = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter textAttributes = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter scriptAttributes = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter stringOffsetOffsets = BinaryWriter(ByteOrder.LittleEndian);
    File newBin = File((json.name ~ "_new.dat"), "wb");
    /*Setup Our Header(Stuff that definitely will not change)*/
	writer.write(to!uint(textScript.header.text_amount)); //Might not actually be text amount
	writer.write(to!uint(textScript.header.unk1)); //Random unk
	writer.write(to!uint(textScript.header.header_size)); //This should stay constant
	/*Thats it! Everything else can be influenced by text size. So lets put all of our text into a data buffer*/
	wchar[] string_buffer;
	ulong[] string_lengths; //These will be useful for calculating offsets later
	ulong[] manual_string_offsets;
	bool[] has_manual_string_offset;
	ulong[] attribute_lengths;
	ulong[] attribute_offsets;
	ulong lineCount; // Just for noting when a line is parsed
	foreach(TextInfo text; textScript.text_info)
	{
		bool inID, inASCII = false;
		bool ASCII_extraZero = false; //Sometimes they add in an extra terminator
		bool ID_firstNumber = false; //Sometimes they want "0" and not 0
		bool textIsToken = false;
		bool manualCodePoint = false; //Mainly for surrogate pairs
		string manualCodePointChar;
		ushort manualCodePointData;
		//Hold on! Check for special tokens before we continue on
		if (text.text_contents == "{{DEC0D0B000B0}}")
		{
			textIsToken = true;
			//writeln("Found uDEC0 token, exporting original data...");
			textContent.write(to!ushort(57024)); //Write the raw values to the file
			textContent.write(to!ushort(53424));
			textContent.write(to!ushort(176));
		}
		if (!textIsToken)
		{
			foreach(wchar _char; text.text_contents)
			{
				if (_char == to!wchar("<") && !inID)
				{
					inID = true;
					continue;
				}
				
				if (_char == to!wchar(">"))
				{
					if (inID)
					{
						inID = false;
						ID_firstNumber = false;
						continue;
					}
					else //Huh, this just appears on its own then
					{
						textContent.write(to!wchar(">"));
						continue;
					}
				}
				
				if (_char == to!wchar("{") && !inID)
				{
					inASCII = true;
					//We can insert a value here with confidence since ascii variables commands start with 0x3
					//string_buffer ~= to!ushort(3);
					textContent.write(to!ushort(3));
					continue;
				}
				
				if (_char == to!wchar("}") && !inID)
				{
					textContent.write(to!ubyte(0));
					if (ASCII_extraZero)
					{
						textContent.write(to!ubyte(0));
						ASCII_extraZero = false;
					}
					inASCII = false;
					continue;
				}
				
				if (_char == to!wchar("⟦")) //Mathematical Opening Square Bracket
				{
					manualCodePoint = true;
					continue;
				}
				
				if (_char == to!wchar("⟧")) //Mathematical Closing Square Bracket
				{
					manualCodePoint = false;
					manualCodePointData = to!ushort(manualCodePointChar, 16);
					textContent.write(manualCodePointData);
					manualCodePointChar = "";
					continue;
				}
				
				if (manualCodePoint)
				{
					manualCodePointChar ~= _char;
					continue;
				}
				
				if (inID)
				{
					//Is our char numeric?
					if (isNumeric(to!string(_char)) && to!ushort(to!string(_char)) < 3)
					{
						//writeln("Char in ID is numeric!");
						//Write it as a number
						//writeln(to!ushort(_char));
						//string_buffer ~= to!ushort(to!string(_char));
						if (!ID_firstNumber)
						{
							ID_firstNumber = true;
							textContent.write(to!ushort(to!string(_char)));
							continue;
						}
						textContent.write(_char);
						continue;
					}
				}
				
				if (inASCII)
				{
					//Skip commas and spaces
					if (_char == to!wchar(" ") || _char == to!wchar(","))
					{
						continue;
					}
					
					//Do we need to add an extra terminator at the end?
					if (_char == to!wchar("+"))
					{
						ASCII_extraZero = true;
						continue;
					}
					
					//Is our char numeric?
					if (isNumeric(to!string(_char)))
					{
						//writeln("Char in ID is numeric!");
						//Write it as a number
						//string_buffer ~= to!ushort(to!string(_char));
						textContent.write(to!ushort(to!string(_char)));
						continue;
					}
					
					//We have to write down anything else as stright ascii, no unicode!
					//string_buffer ~= to!char(cast(ubyte)_char);
					textContent.write(to!char(cast(ubyte)_char));
					continue;
				}
				
				//If we didn't pass any checks, add the char to the buffer!
				//string_buffer ~= _char;
				textContent.write(_char);
			}
		}
		//Don't create ANY data if we have a strange offset, dont apply terminator if we dont have one
		if (!text.hasManualOffset && !textIsToken && !text.noTerminator)
		{
			textContent.write(cast(wchar)0);
		}
		//Note down length of buffer and its manual Offset(not always used)
		manual_string_offsets ~= text.manualOffset;
		has_manual_string_offset ~= text.hasManualOffset;
		string_lengths ~= textContent.buffer.length;
		lineCount += 1;
		writefln("Line %s parsed", lineCount);
	}
	//writefln("textContent length: %s", textContent.buffer.length);
	//Lets add in the script attributes now since they come right after the text
	foreach(string attribute; textScript.attributes.attributeStrings)
	{
		attribute_offsets ~= 64 + textContent.buffer.length;
		textContent.writeArray(cast(char[])attribute);
		textContent.write(cast(ubyte)0);
		attribute_lengths ~= attribute.length + 1;
	}
	//writefln("textContent length after attributes: %s", textContent.buffer.length);
	//Ok we should have all text accounted for now, lets prepare the next header value
	if (textContent.buffer.length % 0x10 == 0xF || textContent.buffer.length % 0x10 == 0xA) //HACK: pad reported length by one if mod 16 gives us 15 or 10
	{
		writer.write(to!uint(textContent.buffer.length + 1));
	}
	else
	{
		writer.write(to!uint(textContent.buffer.length));
	}
	//Now pad out textContent to the next 0x10 bytes since we have written proper length
	ulong text_length = textContent.buffer.length;
	if (textContent.buffer.length % 0x10 != 0x0) //HACK: if length mod 16 = 0, dont pad, because this script format loves being inconsistent
	{
		while (textContent.buffer.length % 0x20 != 0)
		{
			textContent.writeArray(new ubyte[1]);
		}
	}
	//writefln("textContent length after buffer: %s", textContent.buffer.length);
	//String offset time! This changes depending on the version
	final switch(script_version)
	{
		case 1:
			ulong OldDataIndex = 0;
			ulong OldDataCounter = 0;
			bool handledOldData = false;
			for (int i = 0; i < string_lengths.length; i++)
			{
				if (OldDataCounter != 2 || handledOldData)
				{
					//writeln("Handling Offset");
					if (has_manual_string_offset[i])
					{
						stringOffsets.write(to!uint(manual_string_offsets[i]));
						OldDataCounter += 1;
						handledOldData = false;
						continue;
					}
					else if (i != 0)
					{
						stringOffsets.write(to!uint(64 + string_lengths[i-1]));
						OldDataCounter += 1;
						handledOldData = false;
						continue;
					}
					if (i == 0)
					{
						//First offset is always as 40
						stringOffsets.write(to!uint(64));
						OldDataCounter += 1;
						handledOldData = false;
						continue;
					}
				}
				else
				{
					//writeln("Handling Old Data");
					stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldUnkData));
					stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldIndex));
					stringOffsets.write(to!uint(textScript.old_string_data[OldDataIndex].oldUnkData2));
					handledOldData = true;
					OldDataIndex += 1;
					i -= 1;
					OldDataCounter = 0;
				}
			}
			//Write the last possible old data offset since our loop ended early
			stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldUnkData));
			stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldIndex));
			stringOffsets.write(to!uint(textScript.old_string_data[OldDataIndex].oldUnkData2));
			break;
		case 2:
			break;
		case 3:
			for (int i = 0; i < string_lengths.length; i++)
			{
				if (has_manual_string_offset[i])
				{
					stringOffsets.write(to!uint(manual_string_offsets[i]));
					continue;
				}
				else if (i != 0)
				{
					stringOffsets.write(to!uint(64 + string_lengths[i-1]));
					continue;
				}
				if (i == 0)
				{
					//First offset is always as 40
					stringOffsets.write(to!uint(64));
					continue;
				}
			}
			break;
	}
	//More header values now
	writer.write(to!uint(64 + textContent.buffer.length)); //String offset section offset
	writer.write(to!uint(stringOffsets.buffer.length)); //String offset section size
	//Add 0x10 padding to stringOffsets since we wrote valid length
	while (stringOffsets.buffer.length % 0x10 != 0)
	{
		stringOffsets.writeArray(new ubyte[1]);
	}
	//Write the text attributes offset header and section size
	//Text(?) flags
	foreach (uint flag; textScript.flags)
	{
		textAttributes.write(flag);
	}
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length)); //Attributes offset
	writer.write(to!uint(textAttributes.buffer.length)); //Attributes section size
	//Now we can pad out the textAttributes section
	while (textAttributes.buffer.length % 0x10 != 0)
	{
		textAttributes.writeArray(new ubyte[1]);
	}
	//Now we write the offset to a completely arbitrary section that only points to the Script Attributes
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length));
	writer.write(to!uint(textScript.attributes.attributePairs.length * 8)); //The section size should always be the length of the attribute pairs array times 2
	//Oh yeah lets write that now
	uint attributeCount = 0;
	foreach (AttributePair attribute_pair; textScript.attributes.attributePairs)
	{
		//We need to first figure out what our offset to the specific attribute is, use a variable we setup a while back to do so
		scriptAttributes.write(to!uint(attribute_offsets[attributeCount])); //MASSIVE assumption, it seems the format lists attributes earliest first
		scriptAttributes.write(attribute_pair.value);
		attributeCount += 1;
	}
	//scriptAttributes.write(to!uint(64 + string_lengths[$-1])); //Offset to the script attributes I hope
	//Add 0x10 padding
	while (scriptAttributes.buffer.length % 0x10 != 0)
	{
		scriptAttributes.writeArray(new ubyte[1]);
	}
	//This section just points to the offsets of the offsets for every script, I have no idea why it does this
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + scriptAttributes.buffer.length));
	//Again, handle version differences
	final switch(script_version)
	{
		case 1:
			ubyte datacounter = 0;
			ulong data_offset = 64;
			for (int i = 0; i < string_lengths.length; i++)
			{
				if (textScript.text_info[i].hasEntryInOffsetOffsets && datacounter != 2)
				{
					//writefln("data_offset: %s Buffer Length: %s i: %s", data_offset, textContent.buffer.length, (i*4));
					//writefln("Writing Offset: %s", (data_offset + textContent.buffer.length + i*4));
					stringOffsetOffsets.write(to!uint(data_offset + textContent.buffer.length + i*4));
					datacounter += 1;
				}
				else if(datacounter == 2)
				{
					//writeln("Increasing offset!");
					data_offset += 8;
					//writefln("data_offset: %s Buffer Length: %s i: %s", data_offset, textContent.buffer.length, (i*4));
					//writefln("Writing Offset: %s", (data_offset + textContent.buffer.length + i*4));
					stringOffsetOffsets.write(to!uint(data_offset + textContent.buffer.length + i*4));
					datacounter = 1;
				}
				else
				{
					continue;
				}
			}
			break;
		case 2:
			break;
		case 3:
			for (int i = 0; i < string_lengths.length; i++)
			{
				if (textScript.text_info[i].hasEntryInOffsetOffsets)
				{
					stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + i*4));
				}
				else
				{
					continue;
				}
			}
			break;
	}
	//Also make sure to add the offsets to the attribute pairs!!!!!!!!!!
	for (int i = 0; i < textScript.attributes.attributePairs.length; i++)
	{
		stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + (i * 8)));
	}
	//We don't have to add padding to this section for whatever reason, also divide by four because its a COUNT!!!!
	writer.write(to!uint(stringOffsetOffsets.buffer.length/4));
	//These set of offsets seem to relate to the length of the script text and however much between the script attributes
	ulong beforeLastAttributeLength;
	ulong afterLastAttributeLength;
	for (int i = 0; i < attribute_lengths.length; i++)
	{
		if (i == attribute_lengths.length - 1 || (indexOf(textScript.attributes.attributeStrings[i], "Message") != -1))
		{
			afterLastAttributeLength = beforeLastAttributeLength + attribute_lengths[i];
			break;
		}
		else
		{
			beforeLastAttributeLength += attribute_lengths[i];
		}
	}
	//writefln("beforeLastAttributeLength: %s\nafterLastAttributeLength: %s", beforeLastAttributeLength, afterLastAttributeLength);
	//writefln("string_lengths[$-1]: %s", string_lengths[$-1]);
	writer.write(to!uint(0)); //This is usually 0
	writer.write(to!uint(string_lengths[$-1] + beforeLastAttributeLength)); //Length of text before the last file attribute
	writer.write(to!uint(string_lengths[$-1] + afterLastAttributeLength)); //Length of text including the last file attribute
	writer.write(to!uint(0)); //This is usually 0
	//All done! Lets flush and clear our buffers
	newBin.rawWrite(writer.buffer);
	newBin.rawWrite(textContent.buffer);
	/*File _stringOffsets = File((json.name ~ "_stringOffsets.dat"), "wb");
	_stringOffsets.rawWrite(stringOffsets.buffer);*/
	newBin.rawWrite(stringOffsets.buffer);
	/*File _textAttributes = File((json.name ~ "_textAttributes.dat"), "wb");
	_textAttributes.rawWrite(textAttributes.buffer);*/
	newBin.rawWrite(textAttributes.buffer);
	/*File _scriptAttributes = File((json.name ~ "_scriptAttributes.dat"), "wb");
	_scriptAttributes.rawWrite(scriptAttributes.buffer);*/
	newBin.rawWrite(scriptAttributes.buffer);
	/*File _stringOffsetOffsets = File((json.name ~ "_stringOffsetOffsets.dat"), "wb");
	_stringOffsetOffsets.rawWrite(stringOffsetOffsets.buffer);*/
	newBin.rawWrite(stringOffsetOffsets.buffer);
	writer.clear();
	textContent.clear();
	stringOffsets.clear();
	textAttributes.clear();
	scriptAttributes.clear();
	stringOffsetOffsets.clear();
	return;
}

void repackScript(File json)
{
    const string jsonData = readText(json.name);
    const Json jsonInfo = parseJsonString(jsonData);
    TextScript textScript = deserializeJson!TextScript(jsonInfo);
    BinaryWriter writer = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter textContent = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter stringOffsets = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter textAttributes = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter scriptAttributes = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter stringOffsetOffsets = BinaryWriter(ByteOrder.LittleEndian);
    File newBin = File((json.name ~ "_new.dat"), "wb");
    /*Setup Our Header(Stuff that definitely will not change)*/
	writer.write(to!uint(textScript.header.text_amount)); //Might not actually be text amount
	writer.write(to!uint(textScript.header.unk1)); //Random unk
	writer.write(to!uint(textScript.header.header_size)); //This should stay constant
	/*Thats it! Everything else can be influenced by text size. So lets put all of our text into a data buffer*/
	wchar[] string_buffer;
	ulong[] string_lengths; //These will be useful for calculating offsets later
	ulong[] manual_string_offsets;
	bool[] has_manual_string_offset;
	ulong[] attribute_lengths;
	ulong[] attribute_offsets;
	ulong lineCount; // Just for noting when a line is parsed
	foreach(TextInfo text; textScript.text_info)
	{
		bool inID, inASCII = false;
		bool ASCII_extraZero = false; //Sometimes they add in an extra terminator
		bool ID_firstNumber = false; //Sometimes they want "0" and not 0
		bool textIsToken = false;
		bool manualCodePoint = false; //Mainly for surrogate pairs
		string manualCodePointChar;
		ushort manualCodePointData;
		//Hold on! Check for special tokens before we continue on
		if (text.text_contents == "{{DEC0D0B000B0}}")
		{
			textIsToken = true;
			//writeln("Found uDEC0 token, exporting original data...");
			textContent.write(to!ushort(57024)); //Write the raw values to the file
			textContent.write(to!ushort(53424));
			textContent.write(to!ushort(176));
		}
		if (!textIsToken)
		{
			foreach(wchar _char; text.text_contents)
			{
				if (_char == to!wchar("<") && !inID)
				{
					inID = true;
					continue;
				}
				
				if (_char == to!wchar(">"))
				{
					if (inID)
					{
						inID = false;
						ID_firstNumber = false;
						continue;
					}
					else //Huh, this just appears on its own then
					{
						textContent.write(to!wchar(">"));
						continue;
					}
				}
				
				if (_char == to!wchar("{") && !inID)
				{
					inASCII = true;
					//We can insert a value here with confidence since ascii variables commands start with 0x3
					//string_buffer ~= to!ushort(3);
					textContent.write(to!ushort(3));
					continue;
				}
				
				if (_char == to!wchar("}") && !inID)
				{
					textContent.write(to!ubyte(0));
					if (ASCII_extraZero)
					{
						textContent.write(to!ubyte(0));
						ASCII_extraZero = false;
					}
					inASCII = false;
					continue;
				}
				
				if (_char == to!wchar("⟦")) //Mathematical Opening Square Bracket
				{
					manualCodePoint = true;
					continue;
				}
				
				if (_char == to!wchar("⟧")) //Mathematical Closing Square Bracket
				{
					manualCodePoint = false;
					manualCodePointData = to!ushort(manualCodePointChar, 16);
					textContent.write(manualCodePointData);
					manualCodePointChar = "";
					continue;
				}
				
				if (manualCodePoint)
				{
					manualCodePointChar ~= _char;
					continue;
				}
				
				if (inID)
				{
					//Is our char numeric?
					if (isNumeric(to!string(_char)) && to!ushort(to!string(_char)) < 3)
					{
						//writeln("Char in ID is numeric!");
						//Write it as a number
						//writeln(to!ushort(_char));
						//string_buffer ~= to!ushort(to!string(_char));
						if (!ID_firstNumber)
						{
							ID_firstNumber = true;
							textContent.write(to!ushort(to!string(_char)));
							continue;
						}
						textContent.write(_char);
						continue;
					}
				}
				
				if (inASCII)
				{
					//Skip commas and spaces
					if (_char == to!wchar(" ") || _char == to!wchar(","))
					{
						continue;
					}
					
					//Do we need to add an extra terminator at the end?
					if (_char == to!wchar("+"))
					{
						ASCII_extraZero = true;
						continue;
					}
					
					//Is our char numeric?
					if (isNumeric(to!string(_char)))
					{
						//writeln("Char in ID is numeric!");
						//Write it as a number
						//string_buffer ~= to!ushort(to!string(_char));
						textContent.write(to!ushort(to!string(_char)));
						continue;
					}
					
					//We have to write down anything else as stright ascii, no unicode!
					//string_buffer ~= to!char(cast(ubyte)_char);
					textContent.write(to!char(cast(ubyte)_char));
					continue;
				}
				
				//If we didn't pass any checks, add the char to the buffer!
				//string_buffer ~= _char;
				textContent.write(_char);
			}
		}
		//Don't create ANY data if we have a strange offset, dont apply terminator if we dont have one
		if (!text.hasManualOffset && !textIsToken && !text.noTerminator)
		{
			textContent.write(cast(wchar)0);
		}
		//Note down length of buffer and its manual Offset(not always used)
		manual_string_offsets ~= text.manualOffset;
		has_manual_string_offset ~= text.hasManualOffset;
		string_lengths ~= textContent.buffer.length;
		lineCount += 1;
		writefln("Line %s parsed", lineCount);
	}
	//writefln("textContent length: %s", textContent.buffer.length);
	//Lets add in the script attributes now since they come right after the text
	foreach(string attribute; textScript.attributes.attributeStrings)
	{
		attribute_offsets ~= 64 + textContent.buffer.length;
		textContent.writeArray(cast(char[])attribute);
		textContent.write(cast(ubyte)0);
		attribute_lengths ~= attribute.length + 1;
	}
	//writefln("textContent length after attributes: %s", textContent.buffer.length);
	//Ok we should have all text accounted for now, lets prepare the next header value
	if (textContent.buffer.length % 0x10 == 0xF || textContent.buffer.length % 0x10 == 0xA) //HACK: pad reported length by one if mod 16 gives us 15 or 10
	{
		writer.write(to!uint(textContent.buffer.length + 1));
	}
	else
	{
		writer.write(to!uint(textContent.buffer.length));
	}
	//Now pad out textContent to the next 0x10 bytes since we have written proper length
	ulong text_length = textContent.buffer.length;
	if (textContent.buffer.length % 0x10 != 0x0) //HACK: if length mod 16 = 0, dont pad, because this script format loves being inconsistent
	{
		while (textContent.buffer.length % 0x20 != 0)
		{
			textContent.writeArray(new ubyte[1]);
		}
	}
	//writefln("textContent length after buffer: %s", textContent.buffer.length);
	//String offset time!
	for (int i = 0; i < string_lengths.length; i++)
	{
		if (has_manual_string_offset[i])
		{
			stringOffsets.write(to!uint(manual_string_offsets[i]));
			continue;
		}
		else if (i != 0)
		{
			stringOffsets.write(to!uint(64 + string_lengths[i-1]));
			continue;
		}
		if (i == 0)
		{
			//First offset is always as 40
			stringOffsets.write(to!uint(64));
			continue;
		}
	}
	//More header values now
	writer.write(to!uint(64 + textContent.buffer.length)); //String offset section offset
	writer.write(to!uint(stringOffsets.buffer.length)); //String offset section size
	//Add 0x10 padding to stringOffsets since we wrote valid length
	while (stringOffsets.buffer.length % 0x10 != 0)
	{
		stringOffsets.writeArray(new ubyte[1]);
	}
	//Write the text attributes offset header and section size
	//Text(?) flags
	foreach (uint flag; textScript.flags)
	{
		textAttributes.write(flag);
	}
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length)); //Attributes offset
	writer.write(to!uint(textAttributes.buffer.length)); //Attributes section size
	//Now we can pad out the textAttributes section
	while (textAttributes.buffer.length % 0x10 != 0)
	{
		textAttributes.writeArray(new ubyte[1]);
	}
	//Now we write the offset to a completely arbitrary section that only points to the Script Attributes
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length));
	writer.write(to!uint(textScript.attributes.attributePairs.length * 8)); //The section size should always be the length of the attribute pairs array times 2
	//Oh yeah lets write that now
	uint attributeCount = 0;
	foreach (AttributePair attribute_pair; textScript.attributes.attributePairs)
	{
		//We need to first figure out what our offset to the specific attribute is, use a variable we setup a while back to do so
		scriptAttributes.write(to!uint(attribute_offsets[attributeCount])); //MASSIVE assumption, it seems the format lists attributes earliest first
		scriptAttributes.write(attribute_pair.value);
		attributeCount += 1;
	}
	//scriptAttributes.write(to!uint(64 + string_lengths[$-1])); //Offset to the script attributes I hope
	//Add 0x10 padding
	while (scriptAttributes.buffer.length % 0x10 != 0)
	{
		scriptAttributes.writeArray(new ubyte[1]);
	}
	//This section just points to the offsets of the offsets for every script, I have no idea why it does this
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + scriptAttributes.buffer.length));
	for (int i = 0; i < string_lengths.length; i++)
	{
		if (textScript.text_info[i].hasEntryInOffsetOffsets)
		{
			stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + i*4));
		}
		else
		{
			continue;
		}
	}
	//Also make sure to add the offsets to the attribute pairs!!!!!!!!!!
	for (int i = 0; i < textScript.attributes.attributePairs.length; i++)
	{
		stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + (i * 8)));
	}
	//We don't have to add padding to this section for whatever reason, also divide by four because its a COUNT!!!!
	writer.write(to!uint(stringOffsetOffsets.buffer.length/4));
	//These set of offsets seem to relate to the length of the script text and however much between the script attributes
	ulong beforeLastAttributeLength;
	ulong afterLastAttributeLength;
	for (int i = 0; i < attribute_lengths.length; i++)
	{
		if (i == attribute_lengths.length - 1 || (indexOf(textScript.attributes.attributeStrings[i], "Message") != -1))
		{
			afterLastAttributeLength = beforeLastAttributeLength + attribute_lengths[i];
			break;
		}
		else
		{
			beforeLastAttributeLength += attribute_lengths[i];
		}
	}
	//writefln("beforeLastAttributeLength: %s\nafterLastAttributeLength: %s", beforeLastAttributeLength, afterLastAttributeLength);
	//writefln("string_lengths[$-1]: %s", string_lengths[$-1]);
	writer.write(to!uint(0)); //This is usually 0
	writer.write(to!uint(string_lengths[$-1] + beforeLastAttributeLength)); //Length of text before the last file attribute
	writer.write(to!uint(string_lengths[$-1] + afterLastAttributeLength)); //Length of text including the last file attribute
	writer.write(to!uint(0)); //This is usually 0
	//All done! Lets flush and clear our buffers
	newBin.rawWrite(writer.buffer);
	newBin.rawWrite(textContent.buffer);
	/*File _stringOffsets = File((json.name ~ "_stringOffsets.dat"), "wb");
	_stringOffsets.rawWrite(stringOffsets.buffer);*/
	newBin.rawWrite(stringOffsets.buffer);
	/*File _textAttributes = File((json.name ~ "_textAttributes.dat"), "wb");
	_textAttributes.rawWrite(textAttributes.buffer);*/
	newBin.rawWrite(textAttributes.buffer);
	/*File _scriptAttributes = File((json.name ~ "_scriptAttributes.dat"), "wb");
	_scriptAttributes.rawWrite(scriptAttributes.buffer);*/
	newBin.rawWrite(scriptAttributes.buffer);
	/*File _stringOffsetOffsets = File((json.name ~ "_stringOffsetOffsets.dat"), "wb");
	_stringOffsetOffsets.rawWrite(stringOffsetOffsets.buffer);*/
	newBin.rawWrite(stringOffsetOffsets.buffer);
	writer.clear();
	textContent.clear();
	stringOffsets.clear();
	textAttributes.clear();
	scriptAttributes.clear();
	stringOffsetOffsets.clear();
	return;
}

void repackScriptOld(File json)
{
    const string jsonData = readText(json.name);
    const Json jsonInfo = parseJsonString(jsonData);
    TextScript textScript = deserializeJson!TextScript(jsonInfo);
    BinaryWriter writer = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter textContent = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter stringOffsets = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter textAttributes = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter scriptAttributes = BinaryWriter(ByteOrder.LittleEndian);
	BinaryWriter stringOffsetOffsets = BinaryWriter(ByteOrder.LittleEndian);
    File newBin = File((json.name ~ "_new.dat"), "wb");
    /*Setup Our Header(Stuff that definitely will not change)*/
	writer.write(to!uint(textScript.header.text_amount)); //Might not actually be text amount
	writer.write(to!uint(textScript.header.unk1)); //Random unk
	writer.write(to!uint(textScript.header.header_size)); //This should stay constant
	/*Thats it! Everything else can be influenced by text size. So lets put all of our text into a data buffer*/
	wchar[] string_buffer;
	ulong[] string_lengths; //These will be useful for calculating offsets later
	ulong[] manual_string_offsets;
	bool[] has_manual_string_offset;
	ulong[] attribute_lengths;
	ulong[] attribute_offsets;
	ulong lineCount; // Just for noting when a line is parsed
	foreach(TextInfo text; textScript.text_info)
	{
		bool inID, inASCII = false;
		bool ASCII_extraZero = false; //Sometimes they add in an extra terminator
		bool ID_firstNumber = false; //Sometimes they want "0" and not 0
		bool textIsToken = false;
		bool manualCodePoint = false; //Mainly for surrogate pairs
		string manualCodePointChar;
		ushort manualCodePointData;
		//Hold on! Check for special tokens before we continue on
		if (text.text_contents == "{{DEC0D0B000B0}}")
		{
			textIsToken = true;
			writeln("Found uDEC0 token, exporting original data...");
			textContent.write(to!ushort(57024)); //Write the raw values to the file
			textContent.write(to!ushort(53424));
			textContent.write(to!ushort(176));
		}
		if (!textIsToken)
		{
			foreach(wchar _char; text.text_contents)
			{
				if (_char == to!wchar("<") && !inID)
				{
					inID = true;
					continue;
				}
				
				if (_char == to!wchar(">"))
				{
					if (inID)
					{
						inID = false;
						ID_firstNumber = false;
						continue;
					}
					else //Huh, this just appears on its own then
					{
						textContent.write(to!wchar(">"));
						continue;
					}
				}
				
				if (_char == to!wchar("{") && !inID)
				{
					inASCII = true;
					//We can insert a value here with confidence since ascii variables commands start with 0x3
					//string_buffer ~= to!ushort(3);
					textContent.write(to!ushort(3));
					continue;
				}
				
				if (_char == to!wchar("}") && !inID)
				{
					textContent.write(to!ubyte(0));
					if (ASCII_extraZero)
					{
						textContent.write(to!ubyte(0));
						ASCII_extraZero = false;
					}
					inASCII = false;
					continue;
				}
				
				if (_char == to!wchar("⟦")) //Mathematical Opening Square Bracket
				{
					manualCodePoint = true;
					continue;
				}
				
				if (_char == to!wchar("⟧")) //Mathematical Closing Square Bracket
				{
					manualCodePoint = false;
					manualCodePointData = to!ushort(manualCodePointChar, 16);
					textContent.write(manualCodePointData);
					manualCodePointChar = "";
					continue;
				}
				
				if (manualCodePoint)
				{
					manualCodePointChar ~= _char;
					continue;
				}
				
				if (inID)
				{
					//Is our char numeric?
					if (isNumeric(to!string(_char)) && to!ushort(to!string(_char)) < 3)
					{
						//writeln("Char in ID is numeric!");
						//Write it as a number
						//writeln(to!ushort(_char));
						//string_buffer ~= to!ushort(to!string(_char));
						if (!ID_firstNumber)
						{
							ID_firstNumber = true;
							textContent.write(to!ushort(to!string(_char)));
							continue;
						}
						textContent.write(_char);
						continue;
					}
				}
				
				if (inASCII)
				{
					//Skip commas and spaces
					if (_char == to!wchar(" ") || _char == to!wchar(","))
					{
						continue;
					}
					
					//Do we need to add an extra terminator at the end?
					if (_char == to!wchar("+"))
					{
						ASCII_extraZero = true;
						continue;
					}
					
					//Is our char numeric?
					if (isNumeric(to!string(_char)))
					{
						//writeln("Char in ID is numeric!");
						//Write it as a number
						//string_buffer ~= to!ushort(to!string(_char));
						textContent.write(to!ushort(to!string(_char)));
						continue;
					}
					
					//We have to write down anything else as stright ascii, no unicode!
					//string_buffer ~= to!char(cast(ubyte)_char);
					textContent.write(to!char(cast(ubyte)_char));
					continue;
				}
				
				//If we didn't pass any checks, add the char to the buffer!
				//string_buffer ~= _char;
				textContent.write(_char);
			}
		}
		if (!text.hasManualOffset && !textIsToken && !text.noTerminator) //Don't create ANY data if we have a strange offset
		{
			textContent.write(cast(wchar)0);
		}
		//Note down length of buffer and its manual Offset(not always used)
		manual_string_offsets ~= text.manualOffset;
		has_manual_string_offset ~= text.hasManualOffset;
		string_lengths ~= textContent.buffer.length;
		lineCount += 1;
		writefln("Line %s parsed", lineCount);
	}
	//writefln("textContent length: %s", textContent.buffer.length);
	//Lets add in the script attributes now since they come right after the text
	foreach(string attribute; textScript.attributes.attributeStrings)
	{
		attribute_offsets ~= 64 + textContent.buffer.length;
		textContent.writeArray(cast(char[])attribute);
		textContent.write(cast(ubyte)0);
		attribute_lengths ~= attribute.length + 1;
	}
	//writefln("textContent length after attributes: %s", textContent.buffer.length);
	//Ok we should have all text accounted for now, lets prepare the next header value
	if (textContent.buffer.length % 0x10 == 0xF || textContent.buffer.length % 0x10 == 0xA) //HACK: pad reported length by one if mod 16 gives us 15 or 10
	{
		writer.write(to!uint(textContent.buffer.length + 1));
	}
	else
	{
		writer.write(to!uint(textContent.buffer.length));
	}
	//Now pad out textContent to the next 0x10 bytes since we have written proper length
	while (textContent.buffer.length % 0x10 != 0)
	{
		textContent.writeArray(new ubyte[1]);
	}
	//writefln("textContent length after buffer: %s", textContent.buffer.length);
	//String offset time! We're handling an old file, so every 2 offsets we need to apply some old data
	ulong OldDataIndex = 0;
	ulong OldDataCounter = 0;
	bool handledOldData = false;
	for (int i = 0; i < string_lengths.length; i++)
	{
		if (OldDataCounter != 2 || handledOldData)
		{
			//writeln("Handling Offset");
			if (has_manual_string_offset[i])
			{
				stringOffsets.write(to!uint(manual_string_offsets[i]));
				OldDataCounter += 1;
				handledOldData = false;
				continue;
			}
			else if (i != 0)
			{
				stringOffsets.write(to!uint(64 + string_lengths[i-1]));
				OldDataCounter += 1;
				handledOldData = false;
				continue;
			}
			if (i == 0)
			{
				//First offset is always as 40
				stringOffsets.write(to!uint(64));
				OldDataCounter += 1;
				handledOldData = false;
				continue;
			}
		}
		else
		{
			//writeln("Handling Old Data");
			stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldUnkData));
			stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldIndex));
			stringOffsets.write(to!uint(textScript.old_string_data[OldDataIndex].oldUnkData2));
			handledOldData = true;
			OldDataIndex += 1;
			i -= 1;
			OldDataCounter = 0;
		}
	}
	//Write the last possible old data offset since our loop ended early
	stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldUnkData));
	stringOffsets.write(to!ushort(textScript.old_string_data[OldDataIndex].oldIndex));
	stringOffsets.write(to!uint(textScript.old_string_data[OldDataIndex].oldUnkData2));
	//More header values now
	writer.write(to!uint(64 + textContent.buffer.length)); //String offset section offset
	writer.write(to!uint(stringOffsets.buffer.length)); //String offset section size
	//Add 0x10 padding to stringOffsets since we wrote valid length
	while (stringOffsets.buffer.length % 0x10 != 0)
	{
		stringOffsets.writeArray(new ubyte[1]);
	}
	//Write the text attributes offset header and section size
	//Text(?) flags
	foreach (uint flag; textScript.flags)
	{
		textAttributes.write(flag);
	}
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length)); //Attributes offset
	writer.write(to!uint(textAttributes.buffer.length)); //Attributes section size
	//Now we can pad out the textAttributes section
	while (textAttributes.buffer.length % 0x10 != 0)
	{
		textAttributes.writeArray(new ubyte[1]);
	}
	//Now we write the offset to a completely arbitrary section that only points to the Script Attributes
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length));
	writer.write(to!uint(textScript.attributes.attributePairs.length * 8)); //The section size should always be the length of the attribute pairs array times 2
	//Oh yeah lets write that now
	uint attributeCount = 0;
	foreach (AttributePair attribute_pair; textScript.attributes.attributePairs)
	{
		//We need to first figure out what our offset to the specific attribute is, use a variable we setup a while back to do so
		scriptAttributes.write(to!uint(attribute_offsets[attributeCount])); //MASSIVE assumption, it seems the format lists attributes earliest first
		scriptAttributes.write(attribute_pair.value);
		attributeCount += 1;
	}
	//scriptAttributes.write(to!uint(64 + string_lengths[$-1])); //Offset to the script attributes I hope
	//Add 0x10 padding
	while (scriptAttributes.buffer.length % 0x10 != 0)
	{
		scriptAttributes.writeArray(new ubyte[1]);
	}
	//This section just points to the offsets of the offsets for every script, I have no idea why it does this
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + scriptAttributes.buffer.length));
	//writefln("string_lengths length: %s", string_lengths.length);
	ubyte datacounter = 0;
	ulong data_offset = 64;
	for (int i = 0; i < string_lengths.length; i++)
	{
		if (textScript.text_info[i].hasEntryInOffsetOffsets && datacounter != 2)
		{
			//writefln("data_offset: %s Buffer Length: %s i: %s", data_offset, textContent.buffer.length, (i*4));
			//writefln("Writing Offset: %s", (data_offset + textContent.buffer.length + i*4));
			stringOffsetOffsets.write(to!uint(data_offset + textContent.buffer.length + i*4));
			datacounter += 1;
		}
		else if(datacounter == 2)
		{
			//writeln("Increasing offset!");
			data_offset += 8;
			//writefln("data_offset: %s Buffer Length: %s i: %s", data_offset, textContent.buffer.length, (i*4));
			//writefln("Writing Offset: %s", (data_offset + textContent.buffer.length + i*4));
			stringOffsetOffsets.write(to!uint(data_offset + textContent.buffer.length + i*4));
			datacounter = 1;
		}
		else
		{
			continue;
		}
	}
	//Also make sure to add the offsets to the attribute pairs!!!!!!!!!!
	for (int i = 0; i < textScript.attributes.attributePairs.length; i++)
	{
		stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + (i * 8)));
	}
	//We don't have to add padding to this section for whatever reason, also divide by four because its a COUNT!!!!
	writer.write(to!uint(stringOffsetOffsets.buffer.length/4));
	//These set of offsets seem to relate to the length of the script text and however much between the script attributes
	ulong beforeLastAttributeLength;
	ulong afterLastAttributeLength;
	for (int i = 0; i < attribute_lengths.length; i++)
	{
		if (i == attribute_lengths.length - 1 || (indexOf(textScript.attributes.attributeStrings[i], "Message") != -1))
		{
			afterLastAttributeLength = beforeLastAttributeLength + attribute_lengths[i];
			break;
		}
		else
		{
			beforeLastAttributeLength += attribute_lengths[i];
		}
	}
	//writefln("beforeLastAttributeLength: %s\nafterLastAttributeLength: %s", beforeLastAttributeLength, afterLastAttributeLength);
	//writefln("string_lengths[$-1]: %s", string_lengths[$-1]);
	writer.write(to!uint(0)); //This is usually 0
	writer.write(to!uint(string_lengths[$-1] + beforeLastAttributeLength)); //Length of text before the last file attribute
	writer.write(to!uint(string_lengths[$-1] + afterLastAttributeLength)); //Length of text including the last file attribute
	writer.write(to!uint(0)); //This is usually 0
	//All done! Lets flush and clear our buffers
	newBin.rawWrite(writer.buffer);
	newBin.rawWrite(textContent.buffer);
	/*File _stringOffsets = File((json.name ~ "_stringOffsets.dat"), "wb");
	_stringOffsets.rawWrite(stringOffsets.buffer);*/
	newBin.rawWrite(stringOffsets.buffer);
	/*File _textAttributes = File((json.name ~ "_textAttributes.dat"), "wb");
	_textAttributes.rawWrite(textAttributes.buffer);*/
	newBin.rawWrite(textAttributes.buffer);
	/*File _scriptAttributes = File((json.name ~ "_scriptAttributes.dat"), "wb");
	_scriptAttributes.rawWrite(scriptAttributes.buffer);*/
	newBin.rawWrite(scriptAttributes.buffer);
	/*File _stringOffsetOffsets = File((json.name ~ "_stringOffsetOffsets.dat"), "wb");
	_stringOffsetOffsets.rawWrite(stringOffsetOffsets.buffer);*/
	newBin.rawWrite(stringOffsetOffsets.buffer);
	writer.clear();
	textContent.clear();
	stringOffsets.clear();
	textAttributes.clear();
	scriptAttributes.clear();
	stringOffsetOffsets.clear();
	return;
}
