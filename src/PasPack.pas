(* $Id$ *)

unit PasPack;

interface

uses
  SysUtils, Classes, Math, ACS_Types, ACS_Procs, Golomb;

type

  TFileHeader = packed record
    Magic : array[0..3] of Char;
    Channels : Word;
    BitsPerSample : Word;
    SampleRate : Word;
    Version : Word;
    TotalFrames : LongWord;
    FramesInBlock : Word;
    VectorLen : Word;
    u, Beta : Single;
  end;

  TBlockHeader = packed record
    M : Word;
    BlockSize : Word;
  end;

  TPPBaseEncoder = class
  protected
    FileHeader : TFileHeader;
    A : array[0..7] of array of Double;
    X0 : array[0..7] of array of Integer;
    HeaderWritten : Boolean;
    FileStream : TStream;
    FBuffer : Pointer;
    X, Y : array[0..7] of array of Integer;
    OutData : array of Integer;
    FBufferSize : LongWord;
    FramesRead : LongWord;
    SBuf : array of Single;
    IBuf : array of Integer;
    procedure Deinterlace; virtual;
    procedure Recalculate(Channel, Offset : Integer; Error : Integer); virtual;
    procedure Filter(Channel, Offset : Integer); virtual;
    procedure Decorrelate; virtual;
    procedure InitFilter; virtual;
    procedure WriteX0;
  public
    constructor Create(const OutputStream : TStream);
    destructor Destroy;
    procedure Init(BPS, Channels, Samplerate : Word); virtual;
    procedure QueryBuffer(var Buffer : Pointer; var BufLength : LongWord);
    procedure Encode; virtual;
    procedure EncodeLastBlock(BufLength : LongWord);
  end;

  TPPFastEncoder = class (TPPBaseEncoder)
  protected
    procedure InitFilter;
  public
    constructor Create(const OutputStream : TStream);
    destructor Destroy;
    procedure Init(BPS, Channels, Samplerate : Word); override;
    procedure SetJoinedStereo;
    procedure Encode; override;
  end;

  TPPBaseDecoder = class
  protected
    FileHeader : TFileHeader;
    A : array[0..7] of array of Double;
    X0 : array[0..7] of array of Integer;
    FileStream : TStream;
    FBuffer : Pointer;
    X, Y : array[0..7] of array of Integer;
    InData : array of Integer;
    FBufferSize : LongWord;
    FramesRead : LongWord;
    FSize : LongWord;
    function GetChannels : Word;
    function GetSampleRate : Word;
    function GetBPS : Word;
    procedure Interlace;
    procedure Recalculate(Channel, Offset : Integer; Error : Integer); virtual;
    procedure Restore(Channel, Offset : Integer); virtual;
    procedure Decorrelate; virtual;
    procedure InitFilter;  virtual;
    procedure ReadX0;
  public
    constructor Create(const InputStream : TStream);
    destructor Destroy;
    function ReadHeader : Boolean; virtual;
    procedure Decode(var Buffer : Pointer; var BufLength : LongWord); virtual;
    property Channels : Word read GetChannels;
    property SampleRate : Word read GetSampleRate;
    property BisPerSample : Word read GetBPS;
    property Size : LongWord read FSize;
  end;

  TPPFastDecoder = class (TPPBaseDecoder)
  protected
    procedure InitFilter; override;
  public
    constructor Create(const InputStream : TStream);
    destructor Destroy;
    function ReadHeader : Boolean; override;
    procedure Decode(var Buffer : Pointer; var BufLength : LongWord); override;
    property Channels : Word read GetChannels;
    property SampleRate : Word read GetSampleRate;
    property Size : LongWord read FSize;
  end;

  TPPAdaptiveEncoder = class(TPPBaseEncoder)
  protected
    procedure Recalculate(Channel, Offset : Integer;  Error : Integer); override;
    procedure InitFilter; override;
  public
    constructor Create(const OutputStream : TStream);
    destructor Destroy;
    procedure Init(BPS, Channels, Samplerate : Word); override;
    procedure SetFilterLength(Length : Word);
    procedure Encode; override;
  end;

  TPPAdaptiveDecoder = class(TPPBaseDecoder)
  protected
    procedure Recalculate(Channel, Offset : Integer; Error : Integer); override;
    procedure InitFilter; override;
  public
    constructor Create(const InputStream : TStream);
    destructor Destroy;
    function ReadHeader : Boolean; override;
    procedure Decode(var Buffer : Pointer; var BufLength : LongWord);  override;
  end;


implementation

  constructor TPPFastEncoder.Create;
  begin
    FileStream := OutputStream;
    HeaderWritten := False;
  end;

  procedure TPPFastEncoder.Init;
  var
    i : Integer;
  begin
    FileHeader.BitsPerSample := BPS;
    FileHeader.Channels := Channels;
    FileHeader.SampleRate := Samplerate;
    FileHeader.Magic := 'PPAK';
    FileHeader.Version := 100;
    FileHeader.TotalFrames := 0;
    FileHeader.FramesInBlock := 512;
    FileHeader.VectorLen := 4;
    FileHeader.u := 0;
    for i := 0 to FileHeader.Channels - 1 do
    begin
      SetLength(A[i], FileHeader.VectorLen);
      SetLength(X0[i], FileHeader.VectorLen);
      SetLength(X[i], FileHeader.FramesInBlock + FileHeader.VectorLen);
      SetLength(Y[i], FileHeader.FramesInBlock);
    end;
    SetLength(SBuf, FileHeader.FramesInBlock*FileHeader.Channels);
    SetLength(IBuf, FileHeader.FramesInBlock*FileHeader.Channels);
    SetLength(OutData, FileHeader.FramesInBlock*FileHeader.Channels);
    FBufferSize := FileHeader.FramesInBlock*(FileHeader.BitsPerSample div 8)*FileHeader.Channels;
    GetMem(FBuffer, FBufferSize);
  end;

  destructor TPPFastEncoder.Destroy;
  begin
    FreeMem(FBuffer);
  end;

  procedure TPPFastEncoder.SetJoinedStereo;
  begin
    FileHeader.u := 1;
  end;

  procedure TPPFastEncoder.Encode;
  var
    i, j : Integer;
    P : PArrayOfByte;
    BS : LongWord;
    BlockHeader : TBlockHeader;
  begin
    if not HeaderWritten then
    begin
      FileStream.Write(FileHeader, SizeOf(FileHeader));
      WriteX0;
      InitFilter;
      HeaderWritten := True;
      Exit;
    end;
    Deinterlace;
    for i := 0 to FileHeader.FramesInBlock -1 do
      for j := 0 to FileHeader.Channels -1 do
      begin
        Filter(j, i);
      end;
    for j := 0 to FileHeader.Channels -1 do
      Move(X[j][FileHeader.FramesInBlock], X0[j][0], FileHeader.VectorLen*SizeOf(X0[j][0]));
    if (FileHeader.Channels = 2) and (FileHeader.u > 0) then
      for i := 0 to FileHeader.FramesInBlock -1 do
          Y[1][i] := Y[1][i] - Y[0][i];
    for j := 0 to FileHeader.Channels -1 do
      for i := 0 to FileHeader.FramesInBlock -1 do
        OutData[j*FileHeader.FramesInBlock + i] := Y[j][i];
    GolombNewBlock(@OutData[0], FileHeader.FramesInBlock*FileHeader.Channels, P, BS, BlockHeader.M);
    BlockHeader.BlockSize := BS;
    FileStream.Write(BlockHeader, SizeOf(BlockHeader));
    FileStream.Write(P^, BlockHeader.BlockSize);
    Inc(FileHeader.TotalFrames, FileHeader.FramesInBlock);
    FreeMem(P);
  end;


  procedure TPPBaseEncoder.Filter;
  var
    i : Integer;
    Sum : Double;
  begin
    Sum := 0;
    for i := 0 to FileHeader.VectorLen - 1 do
      Sum := Sum + A[Channel][i]*X[Channel][i + Offset];
    Y[Channel][Offset] := X[Channel][FileHeader.VectorLen + Offset] - Round(Sum);
  end;

  procedure TPPFastEncoder.InitFilter;
  var
    i : Integer;
  begin
    for i := 0 to FileHeader.Channels - 1 do
    begin
      A[i][0] := -1;
      A[i][1] := 2;
      A[i][2] := -2;
      A[i][3] := 2;
    end;
  end;

  constructor TPPFastDecoder.Create;
  begin
    FileStream := InputStream;
    FBuffer := nil;
  end;

  destructor TPPFastDecoder.Destroy;
  begin
    if FBuffer <> nil then FreeMem(FBuffer);
  end;

  function TPPFastDecoder.ReadHeader;
  var
    i : Integer;
  begin
    FileStream.Read(FileHeader, SizeOf(FileHeader));
    if FileHeader.Magic <> 'PPAK' then
    begin
      Result := False;
      Exit;
    end;
    if not (FileHeader.Version in [100..199]) then
    begin
      Result := False;
      Exit;
    end;
    FramesRead := 0;
    for i := 0 to FileHeader.Channels - 1 do
    begin
      SetLength(A[i], FileHeader.VectorLen);
      SetLength(X0[i], FileHeader.VectorLen);
      SetLength(X[i], FileHeader.FramesInBlock + FileHeader.VectorLen);
      SetLength(Y[i], FileHeader.FramesInBlock);
    end;
    SetLength(InData, FileHeader.FramesInBlock*FileHeader.Channels);
    FBufferSize := FileHeader.FramesInBlock*FileHeader.Channels*(FileHeader.BitsPerSample div 8);
    if FBuffer <> nil then FreeMem(FBuffer);
    GetMem(FBuffer, FBufferSize);
    FSize := FileHeader.TotalFrames*FileHeader.Channels*FileHeader.BitsPerSample div 8;
    InitFilter;
    FramesRead := 0;
    Result := True;
  end;

  procedure TPPFastDecoder.InitFilter;
  var
    i : Integer;
  begin
    for i := 0 to FileHeader.Channels - 1 do
    begin
      A[i][0] := -1;
      A[i][1] := 2;
      A[i][2] := -2;
      A[i][3] := 2;
    end;
  end;

  procedure TPPFastDecoder.Decode;
  var
    i, j : Integer;
    BlockHeader : TBlockHeader;
    Block : PArrayOfByte;
    BlockLen : LongWord;
  begin
    if FramesRead = 0 then
    begin
      ReadX0;
      Interlace;
      Buffer := FBuffer;
      BufLength := FileHeader.VectorLen*FileHeader.Channels*(FileHeader.BitsPerSample div 8);
      Inc(FramesRead);
      Exit;
    end;
    if FramesRead > FileHeader.TotalFrames then
    begin
      Buffer := FBuffer;
      BufLength := 0;
      Exit;
    end;
    FileStream.Read(BlockHeader, SizeOf(BlockHeader));
    GetMem(Block, BlockHeader.BlockSize);
    BlockLen := BlockHeader.BlockSize;
    FileStream.Read(Block^, BlockLen);
    GolombDecodeBlock(@InData[0], FileHeader.FramesInBlock*FileHeader.Channels, Block, BlockHeader.BlockSize, BlockHeader.M);
    FreeMem(Block);
    if (FileHeader.Channels = 2) and (FileHeader.u > 0) then
      for i := 0 to FileHeader.FramesInBlock -1 do
        InData[FileHeader.FramesInBlock + i] := InData[FileHeader.FramesInBlock + i] + InData[i];
    for i := 0 to FileHeader.VectorLen -1 do
      for j := 0 to FileHeader.Channels -1 do
        X[j][i] := X0[j][i];
    for i := 0 to FileHeader.FramesInBlock -1 do
      for j := 0 to FileHeader.Channels -1 do
        X[j][i + FileHeader.VectorLen] := InData[FileHeader.FramesInBlock*j + i];
    for j := 0 to FileHeader.Channels -1 do
      for i := 0 to FileHeader.FramesInBlock -1 do
      begin
        Restore(j, i);
      end;
    for j := 0 to FileHeader.Channels -1 do
      Move(X[j][FileHeader.FramesInBlock], X0[j][0], FileHeader.VectorLen*SizeOf(X0[j][0]));
    Interlace;
    Buffer := FBuffer;
    BufLength := FBufferSize;
    Inc(FramesRead);
  end;

  constructor TPPBaseEncoder.Create;
  begin
  end;

  destructor TPPBaseEncoder.Destroy;
  begin
  end;

  procedure TPPBaseEncoder.Deinterlace;
  var
    P : PInteger;
    i, j, Samples : Integer;
  begin
    Samples := FileHeader.FramesInBlock*FileHeader.Channels;
    if FileHeader.BitsPerSample < 32 then
    begin
      case FileHeader.BitsPerSample of
        8 : for i := 0 to Samples - 1 do IBuf[i] := PBuffer8(FBuffer)[i];
        16 : for i := 0 to Samples - 1 do IBuf[i] := PBuffer16(FBuffer)[i];
        24 :
        begin
          Int24ToSingle(PBuffer8(FBuffer), @SBuf[0], Samples);
          SingleToInt32(@SBuf[0], @IBuf[0], Samples);
        end;
      end;
      P := @IBuf[0];
    end else
      P := FBuffer;
    for i := 0 to FileHeader.VectorLen -1 do
      for j := 0 to FileHeader.Channels -1 do
       X[j][i] := X0[j][i];
    for i := 0 to FileHeader.FramesInBlock -1 do
      for j := 0 to FileHeader.Channels -1 do
      begin
        X[j][i + FileHeader.VectorLen] := P^;
        Inc(P);
      end;
  end;

  procedure TPPBaseEncoder.Decorrelate;
  begin
  end;

  procedure TPPBaseEncoder.InitFilter;
  begin
  end;

  procedure TPPBaseEncoder.Recalculate;
  begin
  end;

  procedure TPPBaseEncoder.Init;
  begin
  end;

  procedure TPPBaseEncoder.QueryBuffer;
  begin
     if not HeaderWritten then
    begin
      Buffer := FBuffer;
      BufLength := FileHeader.VectorLen*FileHeader.Channels*(FileHeader.BitsPerSample div 8);
      Exit;
    end;
    Buffer := FBuffer;
    BufLength := FBufferSize;
  end;

  procedure TPPBaseEncoder.WriteX0;
  var
    i, j : Integer;
  begin
    Deinterlace;
    for i := 0 to FileHeader.VectorLen - 1 do
      for j := 0 to FileHeader.Channels - 1 do
        X0[j][i] := X[j][i + FileHeader.VectorLen];
    for j := 0 to FileHeader.Channels - 1 do
      FileStream.Write(X0[j][0], Length(X0[j])*SizeOf(X0[j][0]));
  end;

  procedure TPPBaseEncoder.Encode;
  begin
  end;

  procedure TPPBaseEncoder.EncodeLastBlock;
  begin
    FBufferSize := BufLength;
    Encode;
    FileStream.Seek(12, soFromBeginning);
    FileStream.Write(FileHeader.TotalFrames, 4);
    FileStream.Seek(0, soFromEnd);
  end;

  constructor TPPBaseDecoder.Create;
  begin
  end;

  destructor TPPBaseDecoder.Destroy;
  begin
  end;

  procedure TPPBaseDecoder.Interlace;
  var
    i, j, k : Integer;
  begin
    k := 0;
    for i := 0 to FileHeader.FramesInBlock -1 do
      for j := 0 to FileHeader.Channels -1 do
      begin
        case FileHeader.BitsPerSample of
          8 : PBuffer8(FBuffer)[k] := Y[j][i];
          16 : PBuffer16(FBuffer)[k] := Y[j][i];
          24, 32 : PBuffer32(FBuffer)[k] := Y[j][i];
        end;
        Inc(k);
      end;
  end;

  procedure TPPBaseDecoder.ReadX0;
  var
    i, j : Integer;
  begin
    for j := 0 to FileHeader.Channels -1 do
      FileStream.Read(X0[j][0], FileHeader.VectorLen*SizeOf(X0[j][0]));
    for i := 0 to FileHeader.VectorLen -1 do
      for j := 0 to FileHeader.Channels -1 do
        Y[j][i] := X0[j][i];
  end;


  procedure TPPBaseDecoder.Recalculate;
  begin
  end;

  procedure TPPBaseDecoder.Restore;
  var
    i : Integer;
    Sum : Double;
  begin
    Sum := 0;
    for i := 0 to FileHeader.VectorLen - 1 do
      Sum := Sum + A[Channel][i]*X[Channel][i + Offset];
    X[Channel][FileHeader.VectorLen + Offset] := X[Channel][FileHeader.VectorLen + Offset] + Round(Sum);
    Y[Channel][Offset] := X[Channel][FileHeader.VectorLen + Offset];
  end;

  procedure TPPBaseDecoder.Decorrelate;
  begin
  end;

  procedure TPPBaseDecoder.InitFilter;
  begin
  end;

  procedure TPPBaseDecoder.Decode;
  begin
  end;

  function TPPBaseDecoder.GetChannels;
  begin
    Result := FileHeader.Channels;
  end;

  function TPPBaseDecoder.GetSampleRate;
  begin
    Result := FileHeader.SampleRate;
  end;

  function TPPBaseDecoder.GetBPS;
  begin
    if FileHeader.BitsPerSample < 24 then
      Result := FileHeader.BitsPerSample
    else
      Result := 32;
  end;

  function TPPBaseDecoder.ReadHeader;
  begin
    Result := False;
  end;

  constructor TPPAdaptiveEncoder.Create;
  begin
    FileStream := OutputStream;
    HeaderWritten := False;
  end;

  destructor TPPAdaptiveEncoder.Destroy;
  begin
    FreeMem(FBuffer);
  end;

  procedure TPPAdaptiveEncoder.Recalculate;
  var
    j : Integer;
  begin
    for j := 0 to FileHeader.VectorLen - 1 do
      A[Channel][j] := A[Channel][j] + X[Channel][Offset + j]*Y[Channel][Offset]*0.00000000001;
  end;

  procedure TPPAdaptiveEncoder.InitFilter;
  var
    i, j : Integer;
  begin
    for i := 0 to FileHeader.Channels - 1 do
    begin
      for j := 0 to FileHeader.VectorLen - 1 do
        A[i][j] := 0;
    end;
  end;

  procedure TPPAdaptiveEncoder.Init;
  var
    i : Integer;
  begin
    FileHeader.BitsPerSample := BPS;
    FileHeader.Channels := Channels;
    FileHeader.SampleRate := Samplerate;
    FileHeader.Magic := 'PPAK';
    FileHeader.Version := 200;
    FileHeader.TotalFrames := 0;
    FileHeader.FramesInBlock := 2048;
    FileHeader.VectorLen := 64;
    FileHeader.u := 0;
    for i := 0 to FileHeader.Channels - 1 do
    begin
      SetLength(A[i], FileHeader.VectorLen);
      SetLength(X0[i], FileHeader.VectorLen);
      SetLength(X[i], FileHeader.FramesInBlock + FileHeader.VectorLen);
      SetLength(Y[i], FileHeader.FramesInBlock);
    end;
    SetLength(SBuf, FileHeader.FramesInBlock*FileHeader.Channels);
    SetLength(IBuf, FileHeader.FramesInBlock*FileHeader.Channels);
    SetLength(OutData, FileHeader.FramesInBlock*FileHeader.Channels);
    FBufferSize := FileHeader.FramesInBlock*(FileHeader.BitsPerSample div 8)*FileHeader.Channels;
    GetMem(FBuffer, FBufferSize);
  end;

  procedure TPPAdaptiveEncoder.SetFilterLength;
  var
    i : Integer;
  begin
    FileHeader.VectorLen := Length;
    for i := 0 to FileHeader.Channels - 1 do
    begin
      SetLength(A[i], FileHeader.VectorLen);
      SetLength(X0[i], FileHeader.VectorLen);
      SetLength(X[i], FileHeader.FramesInBlock + FileHeader.VectorLen);
    end;
  end;

  procedure TPPAdaptiveEncoder.Encode;
  var
    i, j : Integer;
    P : PArrayOfByte;
    BS : LongWord;
    BlockHeader : TBlockHeader;
    e : Integer;
  begin
    if not HeaderWritten then
    begin
      FileStream.Write(FileHeader, SizeOf(FileHeader));
      WriteX0;
      InitFilter;
      HeaderWritten := True;
      Exit;
    end;
    Deinterlace;
    for i := 0 to FileHeader.FramesInBlock -1 do
      for j := 0 to FileHeader.Channels -1 do
      begin
        Filter(j, i);
        Recalculate(j, i, e);
      end;
    for j := 0 to FileHeader.Channels -1 do
      Move(X[j][FileHeader.FramesInBlock], X0[j][0], FileHeader.VectorLen*SizeOf(X0[j][0]));
    for j := 0 to FileHeader.Channels -1 do
      for i := 0 to FileHeader.FramesInBlock -1 do
        OutData[j*FileHeader.FramesInBlock + i] := Y[j][i];
    GolombNewBlock(@OutData[0], FileHeader.FramesInBlock*FileHeader.Channels, P, BS, BlockHeader.M);
    BlockHeader.BlockSize := BS;
    FileStream.Write(BlockHeader, SizeOf(BlockHeader));
    FileStream.Write(P^, BlockHeader.BlockSize);
    Inc(FileHeader.TotalFrames, FileHeader.FramesInBlock);
    FreeMem(P);
  end;

  constructor TPPAdaptiveDecoder.Create;
  begin
    FileStream := InputStream;
    FBuffer := nil;
  end;

  destructor TPPAdaptiveDecoder.Destroy;
  begin
    if FBuffer <> nil then FreeMem(FBuffer);
  end;

  procedure TPPAdaptiveDecoder.InitFilter;
  var
    i, j : Integer;
  begin
    for i := 0 to FileHeader.Channels - 1 do
    begin
      for j := 0 to FileHeader.VectorLen - 1 do
        A[i][j] := 0;
    end
  end;

  procedure TPPAdaptiveDecoder.Recalculate;
  var
    j : Integer;
  begin
    for j := 0 to FileHeader.VectorLen - 1 do
      A[Channel][j] := A[Channel][j] + X[Channel][Offset + j]*Error*0.00000000001;
  end;

  procedure TPPAdaptiveDecoder.Decode;
    var
    i, j : Integer;
    P : PSmallInt;
    BlockHeader : TBlockHeader;
    Block : PArrayOfByte;
    BlockLen : LongWord;
    Error : Integer;
  begin
    if FramesRead = 0 then
    begin
      ReadX0;
      Interlace;
      Buffer := FBuffer;
      BufLength := FileHeader.VectorLen*FileHeader.Channels*(FileHeader.BitsPerSample div 8);
      Inc(FramesRead);
      Exit;
    end;
    if FramesRead > FileHeader.TotalFrames then
    begin
      Buffer := FBuffer;
      BufLength := 0;
      Exit;
    end;
    FileStream.Read(BlockHeader, SizeOf(BlockHeader));
    GetMem(Block, BlockHeader.BlockSize);
    BlockLen := BlockHeader.BlockSize;
    FileStream.Read(Block^, BlockLen);
    GolombDecodeBlock(@InData[0], FileHeader.FramesInBlock*FileHeader.Channels, Block, BlockHeader.BlockSize, BlockHeader.M);
    FreeMem(Block);
    for i := 0 to FileHeader.VectorLen -1 do
      for j := 0 to FileHeader.Channels -1 do
        X[j][i] := X0[j][i];
    for i := 0 to FileHeader.FramesInBlock -1 do
      for j := 0 to FileHeader.Channels -1 do
        X[j][i + FileHeader.VectorLen] := InData[FileHeader.FramesInBlock*j + i];
    for j := 0 to FileHeader.Channels -1 do
    begin
      for i := 0 to FileHeader.FramesInBlock -1 do
      begin
        Error := X[j][i + FileHeader.VectorLen];
        Restore(j, i);
        Recalculate(j, i, Error);
      end;
    end;
    for j := 0 to FileHeader.Channels -1 do
      Move(X[j][FileHeader.FramesInBlock], X0[j][0], FileHeader.VectorLen*SizeOf(X0[j][0]));
    Interlace;
    Buffer := FBuffer;
    BufLength := FBufferSize;
    Inc(FramesRead);
  end;

  function TPPAdaptiveDecoder.ReadHeader;
  var
    i : Integer;
  begin
    FileStream.Read(FileHeader, SizeOf(FileHeader));
    if FileHeader.Magic <> 'PPAK' then
    begin
      Result := False;
      Exit;
    end;
    if (FileHeader.Version < 200) or (FileHeader.Version > 299) then
    begin
      Result := False;
      Exit;
    end;
    for i := 0 to FileHeader.Channels - 1 do
    begin
      SetLength(A[i], FileHeader.VectorLen);
      SetLength(X0[i], FileHeader.VectorLen);
      SetLength(X[i], FileHeader.FramesInBlock + FileHeader.VectorLen);
      SetLength(Y[i], FileHeader.FramesInBlock);
    end;
    SetLength(InData, FileHeader.FramesInBlock*FileHeader.Channels);
    FBufferSize := FileHeader.FramesInBlock*FileHeader.Channels*(FileHeader.BitsPerSample div 8);
    GetMem(FBuffer, FBufferSize);
    FSize := FileHeader.TotalFrames*FileHeader.Channels*FileHeader.BitsPerSample div 8;
    InitFilter;
    FramesRead := 0;
    Result := True;
  end;


end.
