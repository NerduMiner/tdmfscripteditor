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
	uint offset5;
	uint section_size4;
	uint unk3;
	uint offset6;
	uint offset7;
	uint unk4;
}

///Stores Specific Text Entry Info
struct TextInfo {
	uint flags;
	wstring text_contents;
}

///Stores Text Script information
struct TextScript {
	TextHeader header;
	TextInfo[] text_info;
	string[] attributes;
	//string[] strings;
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
	for (int i = 0; i < (header.strings_section_size1 / 4); i++) 
	{
		uint curStringOffset = readU32(script);
		stringOffsetIndex = script.tell();
		script.seek(curStringOffset); //Go to current string
		wstring str;
		while (true)
		{
			ushort char_ = readU16(script);
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
				continue;
			}
			if (char_ == 3) //ASCII?
			{
				str ~= ("{" ~ to!wstring(readU16(script)) ~ ", ");
				while (true)
				{
					ubyte ascii_ = readU8(script);
					if (ascii_ == 0)
					{
						//Sometimes, there can be two 0s instead of one so check for that
						ulong curFileOffset = script.tell();
						if (readU8(script) == 0)
						{
							str ~= ", +}"; //Make sure to tell repacking code to add one extra 00
							break;
						}
						//"No extra 0 needed"
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
				writeln("We aren't valid char yet! Assuming Surrogate Pair...");
				ushort low_surrogate = readU16(script);
				uint newData;
				newData = char_<<16 | low_surrogate;//This is wacky
				uint[] newDataArr;
				newDataArr ~= newData;
				writefln("New UTF: %08X", newData);
				if (!isValidCodepoint(cast(dchar) newData)) //STILL not right???
				{
					//Lets just write both values as escape codes
					writeln("STILL not valid writing as individual escape codes");
					//This is dumb
					ushort lh = newData & 0x0000FFFF;
					ushort uh = newData & 0xFFFF;
					str ~= cast(wstring)("\\" ~ "u" ~ format("%04X", lh) ~ "\\" ~ "u" ~ format("%04X", uh));
				}
				else
				{
					str ~= cast(wstring)newDataArr.assumeUTF;
				}
				continue;
			}
			str ~= data.assumeUTF;
		}
		/*Grabbing the String Flags*/
		script.seek(scriptInfo.header.offset3 + (i * 4));
		scriptInfo.text_info ~= TextInfo(readU32(script), str);
		script.seek(stringOffsetIndex);
		writefln("Line %s at offset %s parsed.", i, curStringOffset);
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
			if (readU8(script) == 0)
			{
				scriptInfo.attributes ~= attribute;
				attribute = "";
				break;
			}
			script.seek(curFileOffset);
			scriptInfo.attributes ~= attribute;
			attribute = "";
		}
		else
		{
			attribute ~= to!char(ascii_);
		}
	}
	/*Now we are all done!*/
	jsonOut.writeln(scriptInfo.serializeToPrettyJson);
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
	ulong[] attribute_lengths;
	foreach(TextInfo text; textScript.text_info)
	{
		//While we are here write down the text attributes
		textAttributes.write(to!uint(text.flags));
		bool inID, inASCII = false;
		bool ASCII_extraZero = false; //Sometimes they add in an extra terminator
		bool ID_firstNumber = false; //Sometimes they want "0" and not 0
		foreach(wchar _char; text.text_contents)
		{
			if (_char == to!wchar("<") && !inID)
			{
				inID = true;
				continue;
			}
			
			if (_char == to!wchar(">"))
			{
				inID = false;
				ID_firstNumber = false;
				continue;
			}
			
			if (_char == to!wchar("{"))
			{
				inASCII = true;
				//We can insert a value here with confidence since ascii variables commands start with 0x3
				//string_buffer ~= to!ushort(3);
				textContent.write(to!ushort(3));
				continue;
			}
			
			if (_char == to!wchar("}"))
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
			
			if (inID)
			{
				//Is our char numeric?
				if (isNumeric(to!string(_char)) && to!ushort(to!string(_char)) < 3)
				{
					writeln("Char in ID is numeric!");
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
					writeln("Char in ID is numeric!");
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
		textContent.write(cast(wchar)0);
		//Note down length of buffer
		string_lengths ~= textContent.buffer.length;
	}
	//Lets add in the script attributes now since they come right after the text
	foreach(string attribute; textScript.attributes)
	{
		textContent.writeArray(cast(char[])attribute);
		textContent.write(cast(ubyte)0);
		attribute_lengths ~= attribute.length + 1;
	}
	//Ok we should have all text accounted for now, lets prepare the next header value
	writer.write(to!uint(textContent.buffer.length));
	//Now pad out textContent to the next 0x10 bytes since we have written proper length
	while (textContent.buffer.length % 0x10 != 0)
	{
		textContent.writeArray(new ubyte[1]);
	}
	//String offset time!
	for (int i = 0; i < string_lengths.length; i++)
	{
		if (i == 0)
		{
			//First offset is always as 40
			stringOffsets.write(to!uint(64));
			continue;
		}
		stringOffsets.write(to!uint(64 + string_lengths[i-1]));
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
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length)); //Attributes offset
	writer.write(to!uint(textAttributes.buffer.length)); //Attributes section size
	//Now we can pad out the textAttributes section
	while (textAttributes.buffer.length % 0x10 != 0)
	{
		textAttributes.writeArray(new ubyte[1]);
	}
	//Now we write the offset to a completely arbitrary section that only points to the Script Attributes
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length));
	writer.write(to!uint(8)); //The section size should always be 4 bytes
	//Oh yeah lets write that now
	scriptAttributes.write(to!uint(64 + string_lengths[$-1])); //Offset to the script attributes I hope
	//Add 0x10 padding
	while (scriptAttributes.buffer.length % 0x10 != 0)
	{
		scriptAttributes.writeArray(new ubyte[1]);
	}
	//This section just points to the offsets of the offsets for every script, I have no idea why it does this
	writer.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length + scriptAttributes.buffer.length));
	for (int i = 0; i < string_lengths.length; i++)
	{
		stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + i*4));
	}
	//Also make sure to add the offset to the 8 byte section!!!! cause it needs it!!!!
	stringOffsetOffsets.write(to!uint(64 + textContent.buffer.length + stringOffsets.buffer.length + textAttributes.buffer.length));
	//We don't have to add padding to this section for whatever reason, also divide by four because its a COUNT!!!!
	writer.write(to!uint(stringOffsetOffsets.buffer.length/4));
	//These set of offsets seem to relate to the length of the script text and however much between the script attributes
	writer.write(to!uint(0)); //This is usually 0
	writer.write(to!uint(string_lengths[$-1] + attribute_lengths[0])); //Length of text including 1st script attribute name
	writer.write(to!uint(string_lengths[$-1] + attribute_lengths[0] + attribute_lengths[1])); //Length of text including 1st & 2nd script attribute names
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
