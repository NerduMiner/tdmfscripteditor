import tdmfscript;
import std.file;
import std.path;
import std.stdio;

int main(string[] args)
{
	if (args.length == 1)
	{
		throw new Exception("No arguments given, please supply command and/or its arguments.");
	}
	switch(args[1]) 
	{
		case "extract":
			File script = File(args[2], "rb");
			extractScript(script);
			return 0;
		case "repack":
			File json = File(args[2], "r");
			repackScript(json);
			return 0;
		default:
			return 1;
	}
}
