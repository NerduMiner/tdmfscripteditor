module binread;
import std.file;
import std.stdio;
import binary.reader;
import binary.common;

///Returns a ubyte from the target file
ubyte readU8(File input) {
    ubyte[] data;
    data.length = 1;
    input.rawRead(data);
    auto reader = binaryReader(data);
    return reader.read!ubyte;
}

///Returns a ushort from the target file
ushort readU16(File input, ByteOrder byteorder = ByteOrder.LittleEndian) {
    ubyte[] data;
    data.length = 2;
    input.rawRead(data);
    auto reader = binaryReader(data, byteorder);
    return reader.read!ushort;
}

///Returns a uint from the target file
uint readU32(File input, ByteOrder byteorder = ByteOrder.LittleEndian) {
    ubyte[] data;
    data.length = 4;
    input.rawRead(data);
    auto reader = binaryReader(data, byteorder);
    return reader.read!uint;
}

///Reads a certain amount of characters, combining them into a returned string
string readString(File input, uint charAmount) {
    ubyte[] data;
    data.length = charAmount;
    input.rawRead(data);
    return cast(string)data;
}

///Reads a certain amount of characters, returning them as a ushort array
ushort[] readUTF16Array(File input, uint charAmount) {
	ushort[] data;
	data.length = charAmount;
    input.rawRead(data);
    return data;
}

///Reads a certain amount of bytes without parsing them
void skipAmount(File input, uint amount) {
    ubyte[] data;
    data.length = amount;
    input.rawRead(data);
    return;
}

///Reads a certain amount of bytes, returning them as a ubyte array 
ubyte[] readAmount(File input, uint amount) {
    ubyte[] data;
    data.length = amount;
    return input.rawRead(data);
}